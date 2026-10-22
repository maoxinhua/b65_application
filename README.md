# B65 AI Workbench

> 第一次在 VS Code 里运行？看 [RUN.md](RUN.md)。

Windows + VS Code control plane for one **Intel Arc Pro B65 32 GB**:

1. **LLM** — `Qwen3.8-Flash-Next IQ3_XXS @ 32K` on **XeStrata** (Strata for Intel GPUs), with selectable IQ2_XS / IQ3_S, start/stop, RAM guard, LAN OpenAI-compatible API and token.
2. **Video** — ComfyUI Intel XPU + Wan2.2 (5B draft / 14B final + 1080p finishing), plus HTML spec cards and an FFmpeg assembler for **IoT module training / promotion videos without human footage**.

Both engines share one GPU, so the workbench enforces an **exclusive mode**: starting one stops the other.

![B65 Workbench dashboard](docs/dashboard.png)

> **Current architecture:** [docs/09-architecture.md](docs/09-architecture.md)  
> Design notes, measurements and licensing: [B65_本地AI落地方案.md](B65_本地AI落地方案.md) (Chinese, v2.1 historical + v3 summary).

---

## Quick start

Open the folder in VS Code, then run the tasks (`Terminal -> Run Task`) or use a PowerShell terminal:

```powershell
.\b65.ps1 setup                 # folders + portable 7-Zip + FFmpeg
.\b65.ps1 install llm           # XeStrata binaries (no model yet)
.\b65.ps1 install llm -Model IQ3_XXS -RunSetup -NoStart -SetDefault  # 76 GB, recommended
.\b65.ps1 install llm -Model IQ3_S   -RunSetup -NoStart               # 84 GB, optional max quality
.\b65.ps1 install video         # ComfyUI Intel XPU portable pack

.\b65.ps1 llm start             # starts IQ3_XXS on the stable 8095 port
.\b65.ps1 llm endpoint          # baseURL / model / apiKey / context / options
.\b65.ps1 test-llm -Runs 1      # health + math + Chinese + JSON checks
.\b65.ps1 status                # RAM / VRAM / processes
.\b65.ps1 panel                 # native WinForms control panel
.\b65.ps1 dashboard             # http://127.0.0.1:8099

.\b65.ps1 models -Profile draft # Wan2.2 5B + text encoder + VAE (~18 GB)
.\b65.ps1 video start
.\b65.ps1 render -Profile draft -Image .\assets\products\module.png -Prompt "slow dolly-in, soft rim light, no people"

.\b65.ps1 card -Data .\config\cards\example.json
.\b65.ps1 build -Manifest .\projects\iot-demo\manifest.json
```


## LLM model profiles

| Model | Download | RAM needed | Quality / use |
|---|---:|---:|---|
| **IQ3_XXS** | 76 GB | ~60 GB | default; best balance on 64 GB |
| **IQ3_S** | 84 GB | ~62 GB | highest quality; close other apps |
| **IQ2_XS** | 68 GB | ~48 GB | fast fallback |

```powershell
.\b65.ps1 install llm -Model IQ3_XXS -RunSetup -NoStart -SetDefault
.\b65.ps1 install llm -Model IQ3_S   -RunSetup -NoStart
.\b65.ps1 llm use    -Model IQ3_XXS   # switch config only
.\b65.ps1 llm switch -Model IQ3_XXS   # switch + restart
```

## Requirements

| Item | Requirement |
|---|---|
| OS | Windows 11 (Windows PowerShell 5.1 is enough) |
| GPU | Intel Arc Pro B65 32 GB, driver **32.0.101.8976** or newer |
| CPU | i9-13900 class (AVX2; AVX-512 not required) |
| RAM | 64 GB (IQ3_XXS `mmap` leaves ~20 GB free; IQ3_S is tight) |
| BIOS | Above 4G Decoding + Re-Size BAR on, CSM off |
| Runtime | .NET 10 Desktop Runtime, VC++ x64 Redistributable |
| Disk | ~280 GB for all three LLM profiles + video models |

The engines run **natively on Windows**; WSL2 is optional and independent. Shutting it down frees ~6–8 GB for the LLM, but is not required (see [docs/08](docs/08-llm-testing-optimization.md)).

The UHD 770 is deliberately left as a **display/QSV-only** device; see [docs/07-igpu.md](docs/07-igpu.md).

## How it works

```
b65.ps1 ── scripts\B65.psm1 (config, state, metrics, process control)
   ├─ Llm.ps1 / Use-LlmModel.ps1 ── model profiles, context/lowRam/kv, start-stop
   ├─ Video.ps1 / Invoke-Render.ps1 ── ComfyUI lifecycle + /prompt + /history
   ├─ Watch-Resources.ps1 ── RAM/VRAM sampler + safety stop
   ├─ Test-Llm.ps1 ── health / quality / token-rate checks
   ├─ Start-Panel.ps1 + app\B65Panel.ps1 ── native WinForms control panel
   ├─ Start-Dashboard.ps1 ── local web console (:8099)
   ├─ New-SpecCard.ps1 ── HTML → Edge headless PNG
   └─ Build-Video.ps1 ── FFmpeg normalize / concat / audio
```

State and logs live in `runtime\` (gitignored): `state.json`, `health.json`, `logs\*.log`, `logs\metrics.jsonl`.

## Windows control panel

```powershell
.\b65.ps1 panel
```

Or double-click `B65 Panel.cmd`, or run the VS Code task **B65: Control panel**.
It is a PowerShell 5.1 + WinForms app: LLM lifecycle, ComfyUI, the
draft → review → final → 1080p ad workflow, logs and an embedded terminal.
See [docs/00-panel.md](docs/00-panel.md).

![B65 Workbench](docs/panel.png)

### LLM testing and tuning

- [IQ3 testing and Windows optimization](docs/08-llm-testing-optimization.md)
- Run `.\b65.ps1 test-llm -Runs 3` for health/model/math/Chinese/JSON checks.

## Commands

| Command | Purpose |
|---|---|
| `setup` | create folders, download 7-Zip + FFmpeg |
| `install llm\|video\|all` | unpack XeStrata / ComfyUI XPU |
| `models -Profile draft\|final` | download model weights (`-Endpoint` to override the mirror) |
| `download-all` | resumable queue: video draft → video final → LLM IQ3_XXS → IQ3_S |
| `downloads` | live download panel; `-Active` shows only in-progress files with speed/ETA |
| `llm start\|stop\|restart\|status` | LLM lifecycle |
| `llm list\|use\|switch\|endpoint` | model profiles, switch, print API endpoint JSON |
| `test-llm -Runs N` | smoke/quality/speed test against the running API |
| `video start\|stop\|restart\|status` | ComfyUI lifecycle |
| `mode llm\|video\|idle` | exclusive switch (stops the other engine) |
| `status [-Json]` | RAM/VRAM/process snapshot |
| `watch -Target llm\|video` | resource watchdog in the foreground |
| `dashboard` | web console on `127.0.0.1:8099` |
| `panel` | native Windows control panel (WinForms, no extra runtime) |
| `render -Profile ... -Image ... -Prompt ...` | submit a Wan2.2 workflow |
| `card -Data ...` | render a 1920×1080 spec card |
| `build -Manifest ...` | assemble the final video |
| `test-workflow -Profile ...` | validate node classes/inputs against ComfyUI |
| `test-qsv` | benchmark CPU vs B65 vs iGPU (UHD 770) H.264 encode |
| `gputemp` | B65 temperature / power / VRAM via Intel xpu-smi (UAC) |
| `doctor` | environment checks |

## RAM / VRAM budget

| Mode | VRAM | RAM | Guard |
|---|---|---|---|
| LLM (IQ3_XXS, 32K, mmap) | ~33 GB (incl. shared) | ~40–60 GB | warn < 8 GB free, stop < 4 GB free × 6 samples |
| Video (Wan2.2 final) | ~26 GB | ~20 GB | watchdog records VRAM; OOM handled by ComfyUI |
| Idle | ~2 GB (desktop) | — | — |

Thresholds are in `config\settings.json` (`watchdog`). The watchdog starts with the engine and writes `runtime\health.json`.

## Directory layout

```
apps\            XeStrata, ComfyUI (downloaded, gitignored)
models\          LLM + ComfyUI weights (gitignored)
tools\           7-Zip, FFmpeg (gitignored)
config\          settings, LLM profiles, model manifest, DSH route template, card data
workflows\       ComfyUI API-format workflows
dashboard\       local web console
app\             WinForms control panel
scripts\         PowerShell control plane
projects\        per-video manifests and cards
assets\          brand, product stills, card template
output\          renders + llm-tests (gitignored)
docs\            architecture (09) / installation / operations / testing
runtime\         state, logs, metrics (gitignored)
```

## Documentation

| Doc | Contents |
|---|---|
| [RUN.md](RUN.md) | VS Code / F5 / task quick start |
| [docs/00-panel.md](docs/00-panel.md) | WinForms control panel |
| [docs/01-install.md](docs/01-install.md) | install, drivers, first run |
| [docs/02-llm.md](docs/02-llm.md) | LLM profiles, API, ports |
| [docs/03-video.md](docs/03-video.md) | ComfyUI / Wan2.2 pipeline |
| [docs/04-operations.md](docs/04-operations.md) | monitoring, downloads, logs |
| [docs/05-troubleshooting.md](docs/05-troubleshooting.md) | common failures |
| [docs/06-local-ai-implementation.md](docs/06-local-ai-implementation.md) | current implementation notes |
| [docs/07-igpu.md](docs/07-igpu.md) | UHD 770 / QSV roles |
| [docs/08-llm-testing-optimization.md](docs/08-llm-testing-optimization.md) | IQ3 testing, WSL, tuning |
| [docs/09-architecture.md](docs/09-architecture.md) | **current architecture** |
| [B65_本地AI落地方案.md](B65_本地AI落地方案.md) | v2.1 design history + v3 summary |

## Licensing

- **Strata** is MIT; **XeStrata** is LGPL-3.0-or-later (fine for internal use; review if you ship the binaries).
- **Qwen3.8-Flash-Next** is under the Qwen Community License 1.0 (separate terms for MaaS / AI-coding products).
- **Wan2.2** is Apache 2.0 — the only model here that is unconditionally safe for commercial advertising.
- **MiniMax H3 / HunyuanVideo / LTX-2** have revenue, territory or MAU restrictions; see the report before using them commercially.

## Safety

- Never start the LLM and video engine together; use `mode` or the dashboard.
- Keep the page file on NVMe and at least 24 GB.
- If the desktop becomes sluggish, run `.\b65.ps1 llm stop`; the watchdog will do it automatically when free RAM stays below 4 GB.
