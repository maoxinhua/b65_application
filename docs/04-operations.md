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
