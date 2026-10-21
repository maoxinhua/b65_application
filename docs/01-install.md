# 01 · 安装

> 所有命令都在 **Windows PowerShell**（不是 WSL bash）里执行，工作目录是项目根目录。
> 安装物全部落在工作路径下：`apps\`、`models\`、`tools\`。

## 0. 前提

| 项 | 要求 |
|---|---|
| 系统 | Windows 11 x64 |
| GPU | Arc Pro B65 32 GB，驱动 `32.0.101.8976` 或更新 |
| CPU | i9-13900（AVX2；无需 AVX-512） |
| 内存 | 64 GB（4×16 DDR5-4000，已满槽） |
| 磁盘 | C 盘/工作盘 ≥ 250 GB 空闲，NVMe |
| 运行时 | .NET 10 Desktop Runtime、VC++ x64 Redistributable |
| 其他 | Git、VS Code、Microsoft Edge（做字幕卡） |

BIOS：**Above 4G Decoding = On**、**Re-Size BAR = On**、**CSM = Off**。GPU 插在电气 x16 槽。

## 1. 初始化工作区

```powershell
cd E:\dsh_project\B65_graphic
.\b65.ps1 setup
.\b65.ps1 doctor
```

`setup` 会创建目录、下载便携版 7-Zip（`tools\7zip\7zr.exe`）和 FFmpeg（`tools\ffmpeg\bin\ffmpeg.exe`）。
`doctor` 应显示 7-Zip / FFmpeg / Edge / .NET 10 为 OK。

## 2. 安装 LLM（XeStrata）

```powershell
.\b65.ps1 install llm
```

脚本从 GitHub Releases 下载 `XeStrata-0.1.45-1-windows-x64.7z` 并解压到 `apps\XeStrata`。

然后**手动完成一次 GUI 设置**（XeStrata 的模型下载/引擎准备是交互式的）：

1. 双击 `apps\XeStrata\xestrata.exe`；
2. GPU 选择 `Intel Arc Pro B65`（必须是 **bmg-g31** 目标，不能是 bmg-g21）；
3. 模型选 **IQ2_XS**（64 GB 内存下的安全档）；
4. 上下文 **32768**；
5. 图片输入先 **关闭**；
6. 等模型下载完成（约 68 GB），能正常对话后关闭窗口。

之后用脚本启动：

```powershell
.\b65.ps1 llm start
.\b65.ps1 llm status
```

> 如果 `--vram-reserve-mib` / `--memory-limit-mib` 不被当前版本接受，把 `config\llm.json` 里的
> `optionalArgs` 改成 `false`，只用 model/context/host/port/api-key 启动。

## 3. 安装视频（ComfyUI Intel XPU）

```powershell
.\b65.ps1 install video
```

来源：`YanWenKun/ComfyUI-WinPortable-XPU`（Intel Arc 整合包，含 PyTorch XPU）。
脚本下载分卷 `ComfyUI_Windows_portable_xpu.7z.001/.002` 和 `models.zip`，解压到
`apps\ComfyUI_windows_portable`，并写入 `ComfyUI\extra_model_paths.yaml` 指向 `models\comfyui`。

首次启动会编译 XPU kernel，可能 1–3 分钟：

```powershell
.\b65.ps1 video start
```

浏览器打开 `http://127.0.0.1:8188`，确认界面能加载。

## 4. 下载视频模型

```powershell
.\b65.ps1 models -Profile draft    # 5B + umt5 + VAE，约 18 GB
.\b65.ps1 models -Profile final    # 14B 高/低噪 + LoRA + VAE，约 30 GB
```

默认走 `hf-mirror.com`（国内快）。要换源：

```powershell
.\b65.ps1 models -Profile draft -Endpoint https://huggingface.co
```

文件清单在 `config\models.json`，可自行增删。下载支持断点续传（`.part` 文件）。

## 5. 验证

```powershell
.\b65.ps1 doctor
.\b65.ps1 card -Data .\config\cards\example.json
.\b65.ps1 build -Manifest .\projects\iot-demo\manifest.json -DryRun
```

- `card` 应生成 `output\cards\rm500q.png`（1920×1080）；
- `build -DryRun` 只打印 FFmpeg 命令，不执行。

## 6. 局域网访问（可选）

LLM 默认监听 `0.0.0.0:8095`。首次放行：

```powershell
.\b65.ps1 llm start -OpenFirewall
```

或手动在“Windows Defender 防火墙 → 入站规则”放行 TCP 8095（仅专用网络）。
API 地址和 Key 在 `llm start` 输出里，也可以 `.\b65.ps1 status` 查看。

## 7. 目录与磁盘

| 目录 | 内容 | 是否入库 |
|---|---|---|
| `apps\` | XeStrata、ComfyUI | 否 |
| `models\` | LLM、Wan2.2、VAE、LoRA | 否 |
| `tools\` | 7-Zip、FFmpeg | 否 |
| `runtime\` | state/health/logs | 否 |
| `output\` | 成片、卡片 | 否 |
| `config\`、`workflows\`、`scripts\`、`docs\` | 代码与配置 | **是** |
