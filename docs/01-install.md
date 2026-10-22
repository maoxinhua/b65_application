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
**这一步不含模型**，先跑一次硬件检查：

```powershell
apps\XeStrata\xestrata-cli.exe --check
```

应看到 `Intel(R) Arc(TM) Pro B65 Graphics, 31 GB VRAM`、`i9-13900 (AVX2)`、`RAM: 64 GB`。

然后二选一完成模型准备（约 68 GB，可断点续传）：

`install llm -RunSetup` 可重复执行。已有 `apps\XeStrata\xestrata-cli.exe` 时不会重新下载或覆盖引擎；
先安装引擎、下镜像中断后再运行同一条命令，会直接从模型准备阶段继续。

**A. 命令行（推荐，模型落在工作路径）**

```powershell
.\b65.ps1 install llm -RunSetup
```

要使用 XeStrata 自带的推荐值确认更新，加 `-CheckUpdate`；不要直接重装来“修复”已存在的引擎。
模型下载中断时重跑同一条命令即可；需要自己选择/回答 XeStrata 的参数时加 `-Interact`。

等价于：

```powershell
xestrata-cli.exe --setup --family qwen --model IQ2_XS --context 32768 \
  --vision no --source modelscope \
  --models-dir models\llm --data-dir runtime\xestrata --yes --no-browser
```

**B. 图形界面**

1. 双击 `apps\XeStrata\xestrata.exe`；
2. GPU 选 `Intel Arc Pro B65`（必须是 **bmg-g31**，不能是 bmg-g21）；
3. 模型 **IQ2_XS**（64 GB 内存下的安全档；工具会推荐 IQ3_XXS，但 60 GB 在 Windows 上偏紧）；
4. 上下文 **32768**；图片输入先关；
5. 完成后把 `config\llm.json` 的 `modelsDir` / `dataDir` 改成 GUI 里实际用的目录（或留空用默认）。

之后启动：

```powershell
.\b65.ps1 llm start
.\b65.ps1 llm status
```

> `--vram-reserve-mib` 如果不被当前版本接受，把 `config\llm.json` 的 `optionalArgs` 改成 `false`。
> `--memory-limit-mib` 这个参数并不存在；XeStrata 用 `--resident-budget-gib` 控制内存，本项目默认不传。

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

LLM 默认配置监听 `0.0.0.0:8095`，但 XeStrata 的 `setup.py` 可能把 `server.py` 绑到其他端口；以 `.\b65.ps1 status` 或面板 LLM 页显示的端口为准。首次放行：

```powershell
.\b65.ps1 llm start -OpenFirewall
```

或手动在“Windows Defender 防火墙 → 入站规则”放行实际 TCP 端口（仅专用网络）。
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
