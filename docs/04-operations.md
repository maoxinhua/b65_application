# 04 · 日常运维

## 一天的节奏

| 时间 | 模式 | 命令 |
|---|---|---|
| 上午写方案/代码 | LLM | `.\b65.ps1 mode llm` |
| 下午出片 | Video | `.\b65.ps1 mode video` |
| 下班/批量 | Video | 队列渲染，见下 |
| 夜间不用 | Idle | `.\b65.ps1 mode idle` |

切换模式会自动停另一个引擎，并等显存释放到 2 GB 以下再启动目标。

## 仪表盘

```powershell
.\b65.ps1 dashboard
```

- 地址 `http://127.0.0.1:8099`，只监听本机；
- 显示 RAM/页面文件/VRAM/GPU 利用率、两个引擎状态、watchdog 状态；
- 按钮：LLM Start/Stop、Video Start/Stop、Mode LLM/Video/Stop all；
- 日志面板可切换 `control/llm/llm.stderr/comfy/comfy.stderr/watchdog/render/dashboard`。

## 监控指标

| 指标 | 正常 | 异常处理 |
|---|---|---|
| RAM free | > 12 GB | < 8 GB 关浏览器；< 4 GB watchdog 会停 LLM |
| Page file | < 30% | > 70% 说明内存不够，降上下文或换 IQ2_XS |
| VRAM dedicated | LLM ~28 GB / 视频 ~26 GB | 接近 32 GB 会 OOM，降分辨率/帧数 |
| GPU util | 视频渲染 80–100% | 长期 0% 说明没跑在 Arc 上，查 `doctor` |
| 专家驻留 | 约 11k/24,576 | 明显偏低：关桌面程序、降上下文 |

## 查 B65 温度

```powershell
.\b65.ps1 gputemp
```

首次会弹 **UAC**：Windows 上 Intel Sysman 是管理员专属，普通 PowerShell 直接跑 `xpu-smi` 会报
`Sysman driver initialization failed`。允许后输出包含：

- GPU Core Temperature（核心温度）
- GPU Memory Temperature / VR（显存、供电温度）
- GPU Power（功耗）
- GPU Memory Used（显存占用）

底层命令（在**管理员** PowerShell 里）：

```powershell
& .\tools\xpu-smi\xpu-smi_2.3.0-8fd5dca_win_2022\xpu-smi.exe --query-gpu=temperature.gpu --id 0
& .\tools\xpu-smi\xpu-smi_2.3.0-8fd5dca_win_2022\xpu-smi.exe stats -d 0
```

`xpu-smi` 由 `.65.ps1 setup` 安装；`--list-gpus` 可看设备编号。
Windows 自带的 WMI 和性能计数器**不暴露** Arc 温度，`Get-Counter` 查不到，别在这上面浪费时间。
如果 xpu-smi 在你的驱动上仍不可用，用 Intel Graphics Software 的 Performance 页，或 HWiNFO64。

## 监控下载进度

最省事的是内置面板（每 5 秒刷新，显示文件、GB、MB/s、ETA、进程和磁盘）：

```powershell
.\b65.ps1 downloads
```

只看一次快照：

```powershell
.\b65.ps1 downloads -Once
```

`-Once` 没有上一次采样，速度会显示 0；要看速度用默认的循环模式。

### 原始 PowerShell 命令

列出所有模型文件（`.part` 是未完成，刷新后才是实时大小）：

```powershell
Get-ChildItem .\models\comfyui, .\models\llm -Recurse -File -Include *.part, *.safetensors, *.gguf |
  ForEach-Object { $_.Refresh(); $_ } |
  Sort-Object LastWriteTime -Descending |
  Select-Object Name,
    @{n='GB';e={[math]::Round($_.Length/1GB,2)}},
    @{n='Updated';e={$_.LastWriteTime.ToString('HH:mm:ss')}} |
  Format-Table -AutoSize
```

单独算某个文件的速度/剩余时间：

```powershell
$f = Get-Item .\models\comfyui\diffusion_models\wan2.2_ti2v_5B_fp16.safetensors.part
$s1 = $f.Length; $t1 = Get-Date
Start-Sleep 5
$f.Refresh()
$mbps = ($f.Length - $s1) / 1MB / ((Get-Date) - $t1).TotalSeconds
$totalGB = 8.72
$remainGB = $totalGB - ($f.Length / 1GB)
"速度 {0:N2} MB/s，剩余 {1:N1} GB，ETA {2:N0} 分钟" -f $mbps, $remainGB, ($remainGB * 1024 / $mbps / 60)
```

看下载队列日志（curl 用 `\r` 刷进度，直接 tail 可能是一长行）：

```powershell
Get-Content .\runtime\logs\download-video-console.log -Tail 10
# 只看最后几段进度：
(Get-Content .\runtime\logs\download-video-console.log -Raw) -split "`r" | Select-Object -Last 3
```

确认下载进程还活着：

```powershell
Get-CimInstance Win32_Process |
  Where-Object Name -in 'curl.exe', 'xestrata-cli.exe', 'python.exe' |
  Select-Object Name, ProcessId, CommandLine
```

看实时网速（所有网卡合计，Mbps）：

```powershell
Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface |
  Where-Object BytesTotalPersec -gt 0 |
  Select-Object Name, @{n='Mbps';e={[math]::Round($_.BytesTotalPersec * 8 / 1MB, 1)}}
```

看磁盘剩余：

```powershell
Get-PSDrive E | Select-Object @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}
```

## 批量渲染

PowerShell 循环调用 `render`，每次换图片/提示词：

```powershell
$shots = @(
  @{ img = "assets\products\a.png"; prompt = "slow dolly-in, soft rim light" },
  @{ img = "assets\products\b.png"; prompt = "slow orbit, cool blue rim light" }
)
foreach ($s in $shots) {
  .\b65.ps1 render -Profile draft -Image $s.img -Prompt $s.prompt -Name ("shot-" + [IO.Path]::GetFileNameWithoutExtension($s.img))
}
```

批量时保持 ComfyUI 常驻；`render` 检测到端口已开就不会重复启动。

## 日志与清理

| 路径 | 内容 | 清理 |
|---|---|---|
| `runtime\logs\*.log` | 控制/引擎日志 | 可直接删 |
| `runtime\logs\metrics.jsonl` | 每 5 秒一条采样 | 按月归档 |
| `runtime\build\` | 组装中间文件 | 可删 |
| `output\shots\` | 每次渲染的 mp4 | 按项目归档 |
| `apps\_download\` | 安装包 | 装完可删 |

## Git 管理

仓库只跟踪代码/配置/文档/工作流/卡片模板；`apps/models/tools/runtime/output` 全部忽略。

```powershell
git status
git add .
git commit -m "feat: ..."
```

修改了 `config\profiles\*.json` 的 node id 或 `workflows\*.json` 后，先跑：

```powershell
.\b65.ps1 test-workflow -Profile final
```

通过后再提交。

## 版本升级

- **XeStrata**：`install llm -Version xe0.1.46-1 -CheckUpdate` 只检查已安装版本；确认升级再使用
  `-Version xe0.1.46-1 -Force`，新版会先解压到临时目录，完整后再替换引擎；模型和设置保留。
- **ComfyUI**：`install video -Force` 先完整下载并校验，再切换安装目录；`extra_model_paths.yaml` 重新生成，
  模型在 `models\` 不受影响。
- **本仓库**：`git pull`，然后 `doctor` + `test-workflow`。

## 备份

必须备份：

1. `config\`（配置）；
2. `projects\`（分镜/卡片数据）；
3. `assets\`（品牌/产品图）；
4. `workflows\`（自定义工作流）。

不需要备份：`apps/`、`models/`、`tools/`、`output/`（可重下/可再生）。
