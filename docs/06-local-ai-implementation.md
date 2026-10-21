# 06 · 本地模型、运行和视频生成的工作方式

> 结论基于当前的 README、设计文档、脚本、模型清单和工作流；目标是 Windows 11 + Arc Pro B65 32 GB + 64 GB RAM。

## 1. 是否需要单独下载模型

需要。这里的“安装引擎”和“下载权重”是两件事：

| 内容 | 当前是否已在工作区 | 准备命令 |
|---|---|---|
| 7-Zip、FFmpeg | 按 `setup` 准备 | `.\b65.ps1 setup` |
| XeStrata Windows 发行包 | 已有 `apps\XeStrata` | `.\b65.ps1 install llm` |
| Qwen3.8-Flash-Next IQ2_XS | **没有**；`models\llm` 尚未安装 | `.\b65.ps1 install llm -RunSetup`，约 68 GiB |
| ComfyUI XPU 便携包 | **当前工作区没有完整安装** | `.\b65.ps1 install video` |
| Wan2.2 草稿权重 | **没有** | `.\b65.ps1 models -Profile draft`，约 18 GiB |
| Wan2.2 终稿权重 | **没有** | `.\b65.ps1 models -Profile final`，约 30 GiB |
| 当前唯一的视频权重 | `models\comfyui\vae\wan_2.1_vae.safetensors`，约 242 MiB | 只是一个 VAE，不能单独生成视频 |

`apps\`、`models\`、`tools\` 都被 `.gitignore` 排除，因此克隆仓库不会带上权重或完整引擎。
`models` 只按项目的 `config\models.json` 下载视频权重；LLM 权重由 XeStrata 的 `--setup` 下载，不是用 ComfyUI 或 `models` 命令下载。

README 给出约 **120 GB LLM + 80 GB 视频** 的磁盘预算；设计文档按完整素材再预留更多空间。
实际先核对剩余空间，不要只按下载清单之和估算。
先 `install llm` 和 `xestrata-cli.exe --check`，硬件检查通过后再下载 68 GB 的模型。

## 2. 构建本地模型服务并安装

### 2.1 推荐路线：发行版 + 启动脚本

当前项目没有编译 XeStrata 或 ComfyUI 引擎的源码构建脚本。本地服务的“build”实际是：

1. 下载 Windows XPU 发行包；
2. 解压并准备模型文件；
3. 用 `b65.ps1` 启动推理服务。

在 **Windows PowerShell** 里，从仓库根目录执行：

```powershell
Set-Location E:\dsh_project\B65_graphic
.\b65.ps1 setup
.\b65.ps1 doctor
.\b65.ps1 install llm
apps\XeStrata\xestrata-cli.exe --check
.\b65.ps1 install llm -RunSetup
.\b65.ps1 install video
.\b65.ps1 models -Profile draft
.\b65.ps1 models -Profile final
.\b65.ps1 video start
.\b65.ps1 test-workflow -Profile draft
.\b65.ps1 llm start
```

`install llm -RunSetup` 会同时做模型准备：`--family qwen --model IQ2_XS --context 32768 --vision no --source modelscope`。
`source` 可根据网络改成 `huggingface`；模型落盘到 `models\llm`，状态和日志落盘到 `runtime\xestrata`。
不要在 bash/WSL 中启动这两个引擎，也不能在 WSL 里走 Intel 图形栈。

每次启动只加载配置中指定的那一个模型：

```powershell
.\b65.ps1 llm start
.\b65.ps1 video start
```

自动下载不会发生在 LLM 的普通启动里：`llm start` 发现 `models\llm` 为空会直接报错，避免误触发大下载。
实际参数和目录见 [config/llm.json](../config/llm.json) 与 [scripts/Invoke-Render.ps1](../scripts/Invoke-Render.ps1)。

### 2.2 从上游源码构建

如果目标不是“装上即可跑”，而是修改/自行编译引擎，则需要另外获取上游源码：

- **XeStrata**：源码构建面向 Linux/SYCL；当前 Windows 使用的是 7z 中的预构建引擎。
  Windows 的 `setup.py` 明确要求 `PACKAGED` 发行包，不能直接把 Linux 构建命令搬到 Windows。
- **ComfyUI XPU**：项目使用 Intel XPU 便携整合包，不维护单独的 `requirements` + 自定义节点锁定构建。
  需要自定义节点时，应在便携包内补装节点，而不是重新创建一套未验证的 Python 环境。

因此，在本仓库的 Windows 交付路径里，**不要先追求“从源码编译”**；先用发行版验证 B65 的驱动、SYCL/Level Zero 和 ComfyUI 工作流。
如果确实要从源码构建 XeStrata，应在 Linux 环境按其上游文档准备 Intel LLVM、SYCL 和相关 GPU 运行时，再单独评估是否能迁移回 Windows；这不是当前 `b65.ps1` 支持的路径。

## 3. LLM 的加载与卸载

### 3.1 当前工作台的层级

当前项目把“模型生命周期”实现为**服务进程生命周期**：

| 操作 | 工作台命令 | 实际效果 |
|---|---|---|
| 加载 | `.\b65.ps1 llm start` | 启动 `xestrata-cli.exe`，等待 `:8095`，探测 `/v1/models`，然后启动内存 watchdog |
| 卸载 | `.\b65.ps1 llm stop` | 停止 LLM 进程及其 watchdog，并释放进程占用的 RAM/VRAM |
| 重载 | `.\b65.ps1 llm restart` | `stop` 后再 `start` |
| 检查 | `.\b65.ps1 llm status` | 查看 PID、端口、模型名、上下文和资源 |

所以，“卸载”不是把某个模型从多模型池中驱逐出来，而是**结束本地推理服务**。
同一块 GPU 上，`llm start` 会先停 ComfyUI；`video start` 会先停 LLM。

### 3.2 XeStrata 自带的模型级卸载

发行包内部还支持不结束服务、仅释放模型的服务接口：

```powershell
$key = (Get-Content .\runtime\state.json | ConvertFrom-Json).llm.apiKey
$headers = @{ Authorization = "Bearer $key" }
$json = '{}'

Invoke-RestMethod -Uri 'http://127.0.0.1:8095/unload?wait=30' `
  -Method Post -Headers $headers -ContentType 'application/json' -Body $json

Invoke-RestMethod -Uri 'http://127.0.0.1:8095/load' `
  -Method Post -Headers $headers -ContentType 'application/json' -Body $json
```

`wait=30` 是等待正在运行的请求结束的秒数（服务默认上限为 300 秒；`wait=1` 使用默认上限）。
按照 XeStrata 当前的接口规则，请求必须带 `Content-Type: application/json`；`/unload` 和 `/load` 不要求解析 JSON 内容，上面的 `{}` 已满足这项检查。
首次请求也会自动重载已卸载的模型。若请求持续忙碌，`/unload` 返回 `busy`，需等待或先停止服务。
这不是当前 `b65.ps1 llm` 的公开命令，建议先用上面两步验证当前 XeStrata 版本是否接受，再把它们封装进工作台。
若需要在模型级释放后等待，也可以给 XeStrata 配置 `idle_unload_s` 或 `--idle-unload`；默认值是 **不卸载**。

### 3.3 显存与内存要分清

- 卸载 LLM = 释放模型服务占用的 RAM 与 VRAM，但会丢失服务进程内的临时对话状态；
- 仅“关闭页面”不等于卸载，浏览器关闭不会停止 `xestrata-cli.exe`；
- 想切到视频，优先 `.\b65.ps1 mode video`，它会先执行排他切换，再启动 ComfyUI；
- `stop` 会强制结束进程树，不要在正在落盘或流式回答时操作。

## 4. 独立创建“文本到视频片段”工具链

### 4.1 当前仓库实际能力

现有 [workflows/wan22_ti2v_5b.api.json](../workflows/wan22_ti2v_5b.api.json) 虽然叫 TI2V，但连接的输入节点是 `LoadImage`，
`Wan22ImageToVideoLatent` 的 `start_image` 指向该图；所以当前 `render` 是**图片驱动的视频生成**，不是纯文本直出。
14B 工作流同样是 `WanImageToVideo` I2V。

要独立做文本直达视频，需要新增一个 **T2V API 工作流**，而不是给现有 I2V 工作流随便传空图片。
本仓库的组装器 [scripts/Build-Video.ps1](../scripts/Build-Video.ps1) 已经能把多个片段、参数卡、图片和音轨拼成最终视频；
它不需要 LLM，也不需要人工镜头。

### 4.2 最小可运行的独立链路

```text
文本分镜
  -> T2V ComfyUI API 工作流
  -> output\shots\*.mp4
  -> 项目 manifest 场景列表
  -> FFmpeg 统一分辨率/帧率并拼接
  -> 可选参数卡、配音和音乐
  -> 最终成片
```

推荐先复用 Wan2.2 的 T2V 模板和 `SaveVideo` 输出。模型的文本编码器、VAE 和扩散模型仍来自
`config\models.json`；不要为一个新的 T2V 节点重新下载一套无关模型。

实施顺序：

1. 保持 ComfyUI 常驻：`.\b65.ps1 video start`。
2. 在 ComfyUI 里加载官方 Wan2.2 T2V 模板，用 **Workflow → Export (API)** 导出。
3. 保存为 `workflows\t2v_wan22.api.json`；确认它只有文本、宽高/帧数、步数/CFG/seed 和视频输出，没有 `LoadImage`。
4. 新增 `config\profiles\video.t2v.json`，映射文本、尺寸、帧数、步数和输出参数。
5. 新增 `scripts/save-shot.ps1`，读取配置后 POST 到 `http://127.0.0.1:8188/prompt`，
   轮询 `/history/<prompt_id>` 并下载视频；不要复制一份带 `-Image` 必填参数的执行器。
6. 把下载路径写入项目 manifest 的 `clip.path`，最后调用 `.\b65.ps1 build -Manifest ...`。

当前 [scripts/Invoke-Render.ps1](../scripts/Invoke-Render.ps1) 强制要求 `-Image`，以及
`test-workflow` 的 profile 只能取 `draft|final`，所以纯文本入口还必须同步扩展这两个脚本，
不能只把 `image` 从配置里删掉。

如果只是先用现成能力出片，不必先写一个新执行器：先用一张产品图/主视觉运行 `render`，再把结果当 `clip`
交给 `build`。这与纯文本 T2V 是两条入口，但最终装配格式相同。

### 4.3 适合的产品视频参数卡

先让模型只负责“场景/机位/材质”，字幕、型号、接口、卖点都交给 HTML 参数卡：

```powershell
.\b65.ps1 card -Data .\config\cards\example.json
```

卡片模板在 `assets\cards\spec-card.html`，数据格式见 `config\cards\example.json`。
把生成的 PNG 和视频片段按顺序写进 `projects\<项目>\manifest.json`，再用：

```powershell
.\b65.ps1 build -Manifest .\projects\<项目>\manifest.json -DryRun
.\b65.ps1 build -Manifest .\projects\<项目>\manifest.json
```

会得到统一的 1920×1080 / 30 fps H.264 成片；音频由 manifest 的 `audio.voice` / `audio.music` 混入。
这比让视频模型直接生成中文字幕可靠得多。

## 5. 独立工具链的接口边界

| 组件 | 输入 | 输出 | 是否共用 GPU |
|---|---|---|---|
| XeStrata | 文本/图片对话、`max_tokens` | OpenAI/Anthropic 兼容响应 | 是，和 ComfyUI 互斥 |
| ComfyUI | API 格式工作流 + 图片/文本参数 | `SaveVideo` 或图片结果 | 是 |
| `save-shot` | T2V 工作流、提示词、seed | 单个视频片段 + JSON 元数据 | 经 ComfyUI（尚待实现） |
| `build` | 项目 manifest | 最终 MP4 | CPU/FFmpeg（不占 GPU） |
| `card` | JSON 卡片数据 | 1920×1080 PNG | CPU/Edge |

将脚本保持为三个边界：**片段生成器**、**场景清单**、**成片装配器**。这样换 T2V 模型、换工作流或加 TTS
都不会破坏已有素材和完整成片。

## 6. 安装后的验证

```powershell
.\b65.ps1 doctor
.\b65.ps1 status
.\b65.ps1 video start
.\b65.ps1 test-workflow -Profile draft
.\b65.ps1 models -Profile draft
.\b65.ps1 render -Profile draft -Image .\assets\products\module.png `
  -Prompt "slow dolly-in, soft rim light, shallow depth of field, no people, no text"
.\b65.ps1 mode llm
.\b65.ps1 llm status
```

验证顺序建议是：先确认 `bmg-g31`/B65 被识别，再确认 ComfyUI `:8188`、工作流节点、模型文件都存在，
最后才做长视频渲染。没有通过 `xestrata-cli.exe --check` 就不要先花时间下载 LLM 权重。

若服务启动失败，先看：

```powershell
Get-Content .\runtime\logs\llm.stderr.log -Tail 100
Get-Content .\runtime\logs\comfy.stderr.log -Tail 100
```

## 7. 已确认的文档修正

`memoryLimitMiB` 不是当前 XeStrata 的参数，也没有对应的工作台配置；旧排错页已改为降低上下文和关闭占内存程序。
LLM 当前没有 `--memory-limit-mib`。要限制内存，只能由引擎的 `--resident-budget-gib`（仅适用某些预算型量化）、
上下文/KV 设置和 watchdog 共同约束；IQ2_XS 本身就需要约 48 GB，不能靠一个不存在的开关“压进 4 GB”。
