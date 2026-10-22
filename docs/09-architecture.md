# 09 · 当前架构（2026-10-22）

> 本文描述的是**已经落地的 Windows 工作台**，不是早期选型估算。  
> 早期估算见 [B65_本地AI落地方案.md](../B65_本地AI落地方案.md)（v2.1，历史）；测试方法见 [08-llm-testing-optimization.md](08-llm-testing-optimization.md)。

## 1. 一句话架构

一个 **Windows 原生 PowerShell 控制面**（`b65.ps1` + `B65.psm1`）管理两套互斥的本地引擎：

- **LLM**：XeStrata（Strata for Intel Arc）加载 `Qwen3.8-Flash-Next IQ3_XXS`，OpenAI 兼容 API 固定 `:8095`；
- **视频**：ComfyUI Intel XPU + Wan2.2（5B draft / 14B final），API `:8188`；
- 外加 WinForms 面板、Web dashboard、测试脚本、watchdog 和资源监控。

同一块 B65 32 GB 显存一次只跑一套，`Mode.ps1` 负责独占切换。

## 2. 组件 / 进程 / 端口

```text
┌──────────────────────────── Windows 11 ────────────────────────────┐
│                                                                    │
│  b65.ps1 (CLI dispatcher)                                          │
│    ├─ app\B65Panel.ps1      WinForms 控制台                        │
│    ├─ Start-Dashboard.ps1  HTTP dashboard :8099                    │
│    ├─ Llm.ps1 ── xestrata-cli.exe                                 │
│    │                 ├─ python setup.py                            │
│    │                 ├─ python serve\server.py ── :8095            │
│    │                 └─ strata.exe (GPU + CPU experts)             │
│    ├─ Video.ps1 ── python_standalone\python.exe main.py ── :8188   │
│    ├─ Watch-Resources.ps1  → runtime\health.json                   │
│    └─ Test-Llm.ps1 / Invoke-Render.ps1 / Build-Video.ps1           │
│                                                                    │
│  DSH (Windows) ── HTTP ── http://10.88.115.60:8095/v1              │
│  WSL2 (optional) ── vmmemWSL, independent of the workbench         │
└────────────────────────────────────────────────────────────────────┘
```

| 进程 | 端口 | 作用 |
|---|---:|---|
| `xestrata-cli.exe` | — | 启动/配置 XeStrata，派生子进程 |
| `python.exe setup.py` | — | 读取 `config\llm.json`、启动 server |
| `python.exe serve\server.py` | **8095** | OpenAI/Anthropic 兼容 API |
| `strata.exe` | — | 真正加载模型、GPU/CPU 专家计算 |
| `python_standalone\python.exe main.py` | **8188** | ComfyUI |
| `Start-Dashboard.ps1` | **8099** | 本地 Web 控制台 |
| `B65Panel.ps1` | — | WinForms 面板 |
| `vmmemWSL` | — | WSL2 VM（可选，约 8 GB private） |

### 端口为什么稳定在 8095

XeStrata 默认会做 warm-up，临时绑一个随机端口；早期因此出现 59643 / 55354 / 63844 等端口，DSH 每次都要改 baseURL。

现在 `config\llm.json` 设置：

```json
"noWarmup": true
```

启动参数追加 `--no-warmup`，服务直接绑配置的 8095。代价是首次请求可能编译 GPU 代码（几十秒），之后走缓存。

`Llm.ps1` 仍会通过 `Get-B65LlmLive` 从 `server.py` 命令行、`/health` 和配置读取**实际**端口；即使以后关掉 `noWarmup`，`status`、面板和 `llm endpoint` 也不会显示错端口。

## 3. LLM 运行时

### 3.1 模型档位

| 档位 | 已下载体积 | `--check` 内存 | 默认 `lowRam` | 用途 |
|---|---:|---:|---|---|
| **IQ3_XXS** | 70.6 GB | ~60 GB | `mmap` | 默认；质量/内存平衡 |
| IQ3_S | 77.9 GB | ~62 GB | `mmap` | 最高质量；64 GB 很紧 |
| IQ2_XS | 63.4 GB | ~48 GB | `auto` | 快速回退 |

文件位置：

```text
models\llm\IQ3_XXS\Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-0000{1,2}-of-00002.gguf
models\llm\IQ3_S\...
models\llm\IQ2_XS\...
```

### 3.2 启动链

`.\b65.ps1 llm start`：

1. 检查是否已有 serving 实例（`Get-B65LlmLive`）；
2. 如果有 `--setup` 下载进程，拒绝启动（避免两个 xestrata）；
3. 若 ComfyUI 在跑，先停掉；
4. 从 `config\llm.json` 读取 `model/context/kv/lowRam/noWarmup/vramReserveMiB`；
5. 启动 `xestrata-cli.exe`；
6. 轮询 `server.py` / `/health`，拿到实际端口、模型 id、上下文；
7. 保存 `runtime\state.json`，启动 watchdog；
8. 打印 LAN URL、模型 id、Key；`llm endpoint` 输出 JSON。

实际参数示例：

```text
xestrata-cli.exe --model IQ3_XXS --context 32768 --host 0.0.0.0 --port 8095
  --api-key <40位> --no-browser --yes --vision no --source modelscope
  --data-dir runtime\xestrata --models-dir models\llm
  --vram-reserve-mib 1024 --kv int8 --low-ram mmap --no-warmup
```

### 3.3 内存布局

| 区域 | 内容 | 实测 |
|---|---|---:|
| VRAM | 模型权重、KV、MTP、部分专家 | ~33 GB（含 shared） |
| RAM | 专家缓存/映射、Windows、WSL | 请求后空闲 20–24 GB |
| SSD | 未驻留专家、pack、MTP | 按需读取 |

`lowRam=mmap` 不把全部专家拉进 RAM，因此 64 GB 机器仍能跑 60 GB 模型；代价是部分专家从 SSD/页缓存读取。

### 3.4 上下文

- 模型原生最大：**262,144（256K）**；
- 默认：**32,768（32K）**；
- 已验证：32K 下 **31,068 token** 的真实输入，prefill 1,291 tok/s，答案正确；
- 40K / 48K / 64K / 96K / 128K / 256K 都能加载，但只做了短请求测试，未填满；
- 日常建议 32K 或 64K，256K 仅适合偶尔的超长输入。

### 3.5 API

- `GET /health`：不需要 Key，返回 `model/max_context/api_key/loaded`；
- `GET /v1/models`：需要 `Authorization: Bearer <key>`；
- `POST /v1/chat/completions`：OpenAI 兼容；
- `POST /v1/messages`：Anthropic 兼容；
- Key 在 `runtime\state.json`，面板/`llm endpoint` 可复制；
- LAN 地址：`http://10.88.115.60:8095/v1`。

## 4. 视频运行时

| 组件 | 位置 / 端口 |
|---|---|
| ComfyUI XPU 便携包 | `apps\ComfyUI_windows_portable` |
| Python | `python_standalone\python.exe` |
| 模型路径 | `models\comfyui`，通过 `extra_model_paths.yaml` 挂入 |
| API | `127.0.0.1:8188` |
| draft 工作流 | `workflows\wan22_ti2v_5b.api.json`（5B） |
| final 工作流 | `workflows\wan22_i2v_14b.api.json`（14B 高/低噪 + 4-step LoRA） |

`Video.ps1` 启动时设置 `TORCH_HOME`、`HF_HUB_CACHE`、`PYTHONPYCACHEPREFIX`，并把 `MinGit\cmd` 加入 `PATH`。

管线：

```text
产品图/提示词
  → draft 5B（832×480）→ 人工检查
  → final 14B（1280×720，4-step LoRA）
  → Invoke-Render 下载 mp4
  → Build-Video：卡片 + 片段 + 音频 → 1920×1080
```

`Build-Video.ps1` 支持 `libx264` / `h264_qsv` / `hevc_qsv`，默认 `libx264`（1080p 实测最快）。

## 5. 控制面

| 入口 | 用途 |
|---|---|
| `b65.ps1` | CLI，所有能力的唯一事实来源 |
| `app\B65Panel.ps1` | WinForms：LLM/视频/广告工作流/日志/终端/设置 |
| `Start-Dashboard.ps1` | Web dashboard `:8099`，适合手机/另一台机器 |
| `Test-Llm.ps1` | API 冒烟、质量、token 速率 |
| `Watch-Resources.ps1` | 5 秒采样，写 `health.json`，低内存自动停 LLM |
| `Doctor.ps1` | 环境/端口/驱动/编码器自检 |
| `Watch-Downloads.ps1` | 下载速度/ETA（`-Active` 只看进行中） |

### 独占模式

`Mode.ps1` 使用全局 mutex：

- `mode llm`：停 ComfyUI，启动 LLM；
- `mode video`：停 LLM，启动 ComfyUI；
- `mode idle`：两者都停。

面板的“启动 LLM/视频”最终也走同一套命令。

## 6. 配置与状态

| 文件 | 内容 |
|---|---|
| `config\llm.json` | 模型、别名、context、lowRam、kv、noWarmup、端口、API 参数 |
| `config\video.json` | ComfyUI 根目录、端口、启动参数 |
| `config\settings.json` | 端口、watchdog 阈值 |
| `config\models.json` | 视频模型清单 |
| `config\profiles\video.*.json` | 工作流节点映射 |
| `config\dsh.qwen38-flash-next.yml` | Windows DSH 路由模板 |
| `config\dsh.wsl.qwen38-flash-next.yml` | WSL2 DSH 路由模板 |
| `runtime\state.json` | 当前 PID/端口/Key/模型/模式（gitignored） |
| `runtime\health.json` | watchdog 最新内存/VRAM/动作（gitignored） |
| `runtime\logs\*.log` | 所有动作/引擎日志（gitignored） |
| `output\` | 视频、卡片、测试记录（gitignored） |

## 7. DSH 集成

同一台机器有两个独立的 DSH 配置：

| 运行位置 | 配置文件 | baseURL |
|---|---|---|
| **Windows DSH** | `C:\Users\<you>\.dsh\cordis.patch.yml` | `http://10.88.115.60:8095/v1` |
| **WSL2 DSH（web）** | `/home/<you>/.dsh/profiles/web/cordis.patch.yml` | `http://127.0.0.1:8095/v1` |

两者都指向同一个 XeStrata 实例，只是网络路径不同：

- WSL2 使用 **mirrored networking**，`127.0.0.1:8095` 可以直接到 Windows 服务；
- WSL2 里访问 `10.88.115.60:8095` 实测被拒（防火墙/镜像细节），所以 WSL 路由用 localhost；
- Windows DSH 用 LAN IP，局域网其他机器也可用。

### 路由（两边同名）

```yaml
qwen38-flash-next:
  displayName: 13900_qwen3.8_flash_next_XEStrata_IQ3_XXS
  apiKeyEnv: QWEN38_FLASH_NEXT_API_KEY
  api: openai-completions
  # Windows: http://10.88.115.60:8095/v1
  # WSL2:    http://127.0.0.1:8095/v1
  baseURL: http://127.0.0.1:8095/v1
  models:
    - id: qwen3.8-flash-next-iq3_xxs
      name: 13900_qwen3.8_flash_next_XEStrata_IQ3_XXS
      contextWindow: 32768
      maxTokens: 8192
      input: [text]
```

### 关键点

- `id` 必须是服务端真实 id `qwen3.8-flash-next-iq3_xxs`；`name/displayName` 才是 `13900_...`；
- Key 放在各自的 `.credentials.yaml`，env 名都是 `QWEN38_FLASH_NEXT_API_KEY`；
- WSL2 改动的是 `profiles/web/cordis.patch.yml`，已备份为 `.bak.<时间>`；
- 改 `context` 后同步改 DSH 的 `contextWindow`；
- 改完如果模型选择器没刷新，重启对应 DSH（Windows 或 WSL）。

## 8. 资源边界

| 状态 | VRAM | RAM 空闲 | 说明 |
|---|---:|---:|---|
| idle | ~2–3 GB | 40+ GB | 桌面 |
| IQ3_XXS 32K mmap | ~33 GB | 20–24 GB | 默认 |
| IQ3_XXS 64K mmap | ~33.9 GB | ~22 GB | 长文档 |
| IQ3_XXS 256K | ~33 GB | ~27 GB | 仅加载验证 |
| IQ3_S | ~33 GB | 更紧 | 需关大程序 |
| ComfyUI final | ~26 GB | ~20 GB | 与 LLM 互斥 |

WSL2 额外占约 6–8 GB；关掉可把 IQ3_XXS 从 `mmap` 切到 `on`（~48 tok/s），但**不是必须**。

## 9. 测试与可观测性

```powershell
.\b65.ps1 status
.\b65.ps1 llm list
.\b65.ps1 llm endpoint
.\b65.ps1 test-llm -Runs 3
.\b65.ps1 downloads -Active
.\b65.ps1 doctor
.\b65.ps1 gputemp
```

- `test-llm` 输出 `output\llm-tests\llm-test-*.md/json/csv`；
- `runtime\health.json` 有 `freeGB/pageFileUsedMB/action`；
- `runtime\logs\llm.log`、`comfy.stderr.log`、`panel-*.log` 是排查入口；
- 面板底部 ACTIVITY LOG 显示当前动作。

## 10. 关键设计决策

1. **Windows 原生，不用 WSL 跑引擎**：Intel Arc 的 Level Zero/SYCL 在 Windows 原生更稳，ComfyUI XPU 也需要原生 VRAM。
2. **XeStrata 而不是官方 Strata**：官方 Windows 包没有 Intel 引擎。
3. **IQ3_XXS 默认**：64 GB 机器上质量/内存的平衡点；IQ3_S 保留但很紧；IQ2_XS 回退。
4. **`lowRam=mmap` 默认**：避免 60 GB 模型把 64 GB 机器压到 1–5 GB 空闲。
5. **`noWarmup=true`**：用首次请求编译换稳定 8095，避免 DSH 端口漂移。
6. **不设 `residentBudgetGiB`**：IQ3_XXS 上设 48 会触发 strata SIGSEGV。
7. **单一 CLI 事实来源**：面板/任务/文档最终都调用 `b65.ps1`，便于脚本化和排查。

## 11. 已知边界

- IQ3_S 未做完整质量/速度基准；256K 只验证加载，未填满；
- 若关闭 `noWarmup`，端口会随机，DSH baseURL 需更新；
- DSH 路由是静态 YAML，改端口/context 后要重启 DSH；
- 4K/200% 缩放下 WinForms 面板逻辑尺寸为 1280×860，视觉上偏大；
- `--resident-budget-gib` 对 IQ3_XXS 不安全；
- PowerShell 5.1 的中文请求体/响应要按 UTF-8 字节处理（`test-llm` 已处理）。
