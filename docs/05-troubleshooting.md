# 05 · 排错

先跑：

```powershell
.\b65.ps1 doctor
.\b65.ps1 status
```

## LLM

| 现象 | 原因 | 处理 |
|---|---|---|
| `XeStrata not found` | 没装或路径不对 | `.\b65.ps1 install llm`；确认 `apps\XeStrata\xestrata-cli.exe` |
| 双击 exe 报缺少框架 | 缺 .NET 10 | 装 [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) |
| 报缺少 `VCRUNTIME140.dll` | 缺 VC++ | 装 [VC++ x64](https://aka.ms/vs/17/release/vc_redist.x64.exe) |
| 启动即退出 | 参数不识别 | 把 `config\llm.json` 的 `optionalArgs` 改 `false`；看 `runtime\logs\llm.stderr.log` |
| 提示 `bmg-g21` / no engine | 装了 B60/B580 的包 | 换 `bmg-g31` 的 XeStrata 构建（B65/B70 同核心） |
| 端口 8095 没起来 | XeStrata 绑到了别的端口，或模型未 setup / 内存不足 | 看 `.\b65.ps1 status` 的实际端口；先跑一次 `xestrata.exe` 完成下载；看 stderr |
| 系统变卡、风扇狂转 | IQ2_XS 锁了 ~48 GB | 关浏览器/编辑器；降低 `context`；watchdog 会在 <4 GB 时停 |
| API 返回 401 | Key 不对 | 用 `.\b65.ps1 status` 里的 Key；Key 存在 `runtime\state.json` |
| 局域网连不上 | 防火墙/绑定地址 | `llm start -OpenFirewall`；确认 `host=0.0.0.0`；同一网段 |
| 输出乱码/重复 | 2-bit 量化 + 高温 | 降上下文；确认没开 `--parallel`；换 IQ3_S 需加内存 |

## 视频（ComfyUI）

| 现象 | 原因 | 处理 |
|---|---|---|
| 8188 起不来 | 首次编译 kernel / 依赖缺失 | 等 3 分钟；看 `runtime\logs\comfy.stderr.log` |
| 页面能开但队列报错 | 工作流节点/输入不匹配 | `.\b65.ps1 test-workflow -Profile draft -Start`，按提示改 `map` |
| `unknown class_type SaveVideo` | ComfyUI 版本较老 | 用官方模板 Export (API) 替换，或改用 `VHS_VideoCombine` |
| 渲染 OOM | 分辨率/帧数太高 | draft 降到 640×352/33 帧；final 降到 960×544/49 帧 |
| 生成很慢 | 跑在 CPU 上 | `doctor` 看 GPU；确认 `OMNI_IMAGE_XPU_TARGET=bmg`；看任务管理器 GPU 占用 |
| 画面糊/闪烁 | 步数太低或提示词冲突 | draft 20 步；final 4 步 LoRA 固定 CFG 1.0；负面词保留 |
| `No output files returned` | SaveVideo 输出键名不同 | 在 ComfyUI 里看实际输出节点；改 `Invoke-Render` 的 `images/gifs/videos` 兼容列表 |
| 文字全乱 | 模型生成中文 | 不要在提示词里写文字；用 `card` 后期贴 |

## 卡片 / 组装

| 现象 | 原因 | 处理 |
|---|---|---|
| `Microsoft Edge not found` | 没装 Edge | 安装 Edge，或改 `Get-B65Edge` 路径 |
| 卡片空白/字体不对 | 页面没加载完 | 提高 `--virtual-time-budget` 到 5000；确认模板 UTF-8 |
| 中文变方块 | 系统缺字体 | 装“微软雅黑”；或在模板里换 `Noto Sans SC` |
| `FFmpeg not found` | 没跑 setup | `.\b65.ps1 setup` |
| build 报 `Clip not found` | 清单里的镜头还没渲染 | 先 `render`，或把该场景删掉/改路径 |
| 音画不同步 | 配音比画面长 | `-shortest` 已启用；调整场景 duration 或剪音频 |
| 输出体积大 | CRF 18 | 改 `Build-Video.ps1` 的 `-crf` 到 20–22 |

## 仪表盘

| 现象 | 处理 |
|---|---|
| 8099 被占用 | `.\b65.ps1 dashboard -Port 8098` |
| 按钮点了没反应 | 看 `runtime\logs\dashboard.log`；动作是后台进程，等 2–3 秒刷新 |
| 页面 404 | 确认 `dashboard\index.html` 存在 |

## PowerShell

| 现象 | 处理 |
|---|---|
| 脚本被策略阻止 | 任务已带 `-ExecutionPolicy Bypass`；手动运行时加 `powershell -ExecutionPolicy Bypass -File .\b65.ps1 ...` |
| 中文路径报错 | 项目路径尽量纯英文；脚本本身是 ASCII |
| `$args` 相关异常 | 已避免使用自动变量；如自行改脚本，不要用 `$args` 作变量名 |

## 仍然不行

收集以下内容再排查：

```powershell
.\b65.ps1 doctor -Json > runtime\doctor.json
.\b65.ps1 status -Json > runtime\status.json
Get-Content runtime\logs\llm.stderr.log -Tail 100
Get-Content runtime\logs\comfy.stderr.log -Tail 100
```

同时记录：驱动版本、XeStrata 版本（`xe0.1.45-1`）、ComfyUI 版本、出错的工作流节点。
