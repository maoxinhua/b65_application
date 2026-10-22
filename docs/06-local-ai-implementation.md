# 06 · 实现说明（当前 Windows 工作台）

> **状态（2026-10-22）**：本文是操作层面的实现说明。完整组件图、端口、数据流和设计决策见
> [09-architecture.md](09-architecture.md)；测试/调优见 [08-llm-testing-optimization.md](08-llm-testing-optimization.md)。
> 早期 v2.1 的 IQ2_XS/随机端口估算已过时。

## 1. 引擎与模型现状

| 组件 | 位置 | 状态 |
|---|---|---|
| XeStrata 0.1.45-1 | `apps\XeStrata` | 已安装，Windows Intel Arc 引擎 |
| IQ3_XXS | `models\llm\IQ3_XXS`，70.6 GB | **默认**，`lowRam=mmap` |
| IQ3_S | `models\llm\IQ3_S`，77.9 GB | 已安装，质量档，内存很紧 |
| IQ2_XS | `models\llm\IQ2_XS`，63.4 GB | 回退档 |
| ComfyUI XPU | `apps\ComfyUI_windows_portable` | 已安装，`:8188` |
| Wan2.2 draft/final | `models\comfyui` | 已下载，工作流已校验 |
| 7-Zip / FFmpeg / xpu-smi | `tools\` | 已安装 |

`apps\`、`models\`、`tools\` 都被 `.gitignore` 排除；新克隆需要重新下载。

## 2. 安装与下载

```powershell
Set-Location E:\dsh_project\B65_graphic

.\b65.ps1 setup
.\b65.ps1 install llm
.\b65.ps1 install video

# LLM 档位（--no-start 不会下载完就抢占显存）
.\b65.ps1 install llm -Model IQ3_XXS -RunSetup -NoStart -SetDefault
.\b65.ps1 install llm -Model IQ3_S   -RunSetup -NoStart

# 视频权重
.\b65.ps1 models -Profile draft
.\b65.ps1 models -Profile final
```

下载进度：

```powershell
.\b65.ps1 downloads -Active
```

## 3. LLM 生命周期

```powershell
.\b65.ps1 llm start
.\b65.ps1 llm stop
.\b65.ps1 llm restart
.\b65.ps1 llm status
.\b65.ps1 llm list
.\b65.ps1 llm endpoint
```

`start` 会：

1. 检测是否已有 serving 实例；如果有 `--setup` 下载进程，拒绝启动；
2. 停掉 ComfyUI（独占显存）；
3. 读 `config\llm.json` 的 model/context/lowRam/kv/noWarmup；
4. 启动 `xestrata-cli.exe`；
5. 通过 `server.py` 命令行 + `/health` 取实际端口、模型 id、上下文；
6. 写 `runtime\state.json`，启动 watchdog；
7. 打印 LAN URL、模型 id、Key。

### 自定义选项

```json
{
  "model": "IQ3_XXS",
  "context": 32768,
  "contextPresets": [32768, 65536, 131072, 262144],
  "lowRam": "mmap",
  "kv": "int8",
  "noWarmup": true,
  "maxOutputTokens": 8192,
  "temperature": 0.7,
  "topP": 0.95
}
```

```powershell
.\b65.ps1 llm use    -Model IQ3_XXS -Context 65536 -LowRam mmap -Kv int8
.\b65.ps1 llm switch -Model IQ3_XXS -Context 65536 -LowRam mmap -Kv int8
```

- `noWarmup=true` 使服务稳定绑 **8095**；
- `lowRam=mmap` 是 IQ3 的默认，避免 64 GB 机器被压到 1–5 GB；
- **不要设 `residentBudgetGiB`**：IQ3_XXS 上设 48 会 SIGSEGV；
- 原生最大上下文 262144，日常建议 32K/64K。

### API

```text
OpenAI    : http://<LAN-IP>:8095/v1
Anthropic : http://<LAN-IP>:8095/v1/messages
Key       : .\b65.ps1 llm endpoint
```

`/health` 不需要 Key；`/v1/models` 和 `/v1/chat/completions` 需要 Bearer。

## 4. 视频管线

```powershell
.\b65.ps1 video start
.\b65.ps1 test-workflow -Profile draft
.\b65.ps1 render -Profile draft -Image .\assets\products\module.png -Prompt "..."
.\b65.ps1 build -Manifest .\projects\iot-demo\manifest.json
```

- draft：Wan2.2 5B，832×480，约 1–2 分钟；
- final：Wan2.2 14B 高/低噪 + 4-step LoRA，1280×720；
- `Build-Video.ps1` 统一 1920×1080/30fps，拼接卡片、片段和音频。

ComfyUI 启动参数包含 `TORCH_HOME`、`HF_HUB_CACHE`、`PYTHONPYCACHEPREFIX`，并把 `MinGit\cmd` 加入 `PATH`。

## 5. 面板、测试与日志

- 面板：`.\b65.ps1 panel` 或 `B65 Panel.cmd`；
- Web dashboard：`.\b65.ps1 dashboard`（`:8099`）；
- 测试：`.\b65.ps1 test-llm -Runs 3`，输出 `output\llm-tests`；
- 状态：`.\b65.ps1 status`、`runtime\health.json`；
- 日志：`runtime\logs\*.log`、面板 ACTIVITY LOG；
- 环境：`.\b65.ps1 doctor`；
- 温度：`.\b65.ps1 gputemp`（首次 UAC）。

## 6. 边界

- LLM 与 ComfyUI 不能同时跑，`mode`/面板会独占切换；
- WSL2 可选，关闭可多 6–8 GB，但 Windows DSH 不受影响；
- DSH 的 `cordis.patch.yml` 是静态的，改 context/端口后要重启 DSH；
- 256K 上下文只验证了“能加载”，32K 已用 31,068 token 真实输入验证；
- IQ3_S 尚未做完整质量/速度基准。
