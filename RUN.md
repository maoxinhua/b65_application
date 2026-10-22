# 在 VS Code 里运行 B65 Workbench

> 这个仓库只包含代码、脚本、工作流和文档。  
> `apps/`、`models/`、`tools/`、`runtime/`、`output/` 都在 `.gitignore` 里，克隆后需要按下面的“首次准备”重新下载。

## 1. 克隆并打开

```powershell
git clone https://github.com/maoxinhua/b65_application.git
cd b65_application
code .
```

VS Code 会提示安装推荐扩展，至少安装 **PowerShell**（`ms-vscode.PowerShell`）。

## 2. 三种启动方式

### 方式 A：F5（Run and Debug）

1. 左侧点 **Run and Debug**（Ctrl+Shift+D）；
2. 顶部选择 **B65: Launch control panel**；
3. 按 **F5**。

面板会以独立窗口打开，VS Code 的调试会话可以随后停止，不影响面板。

### 方式 B：Ctrl+Shift+B（默认 Build Task）

`B65: Control panel` 已设为默认 build task：

- 按 **Ctrl+Shift+B**，或
- **Terminal → Run Build Task**。

### 方式 C：任务面板 / 终端

- **Ctrl+Shift+P** → `Tasks: Run Task` → **B65: Control panel**；
- 或直接在终端：

```powershell
.\b65.ps1 panel
```

也可以双击根目录的 **`B65 Panel.cmd`**。

## 3. 首次准备（新克隆必做）

代码仓库不带引擎和模型。按顺序执行：

```powershell
# 目录 + 7-Zip + FFmpeg + xpu-smi
.\b65.ps1 setup

# XeStrata 引擎（Windows / Intel Arc）
.\b65.ps1 install llm

# ComfyUI Intel XPU 便携包
.\b65.ps1 install video

# 视频权重：先 draft，能出片后再 final
.\b65.ps1 models -Profile draft
.\b65.ps1 models -Profile final

# LLM 权重（约 68 GB，耗时最长，可最后做）
.\b65.ps1 install llm -RunSetup
```

下载进度：

```powershell
.\b65.ps1 downloads
```

## 4. 面板里做什么

| 页面 | 功能 |
|---|---|
| **LLM** | 加载/启动、卸载/停止、重启、打开 API、复制 LAN Base URL / Key |
| **视频** | 启动/停止 ComfyUI、打开 ComfyUI、快速渲染 draft/final、取消当前 |
| **广告工作流** | 产品图 + 描述 → draft 小样 → **暂停检查** → final 14B → 合成 1080p 广告 |
| **日志** | 查看 `runtime\logs\*.log` |
| **终端** | 内嵌 PowerShell，默认项目根目录 |
| **设置** | 打开 `config\*.json`、项目目录 |

### 广告工作流

1. **① 生成 draft 小样**：5B，832×480，约 1–2 分钟；
2. 完成后自动显示首帧，流程停住——这是“暂停”检查点；
3. 满意 → **② 确认 → 生成 final**：14B + 4-step LoRA，1280×720；
4. **③ 合成 1080p 广告**：输出 `output\panel-ad.mp4`。

> ComfyUI 不支持渲染中途暂停/继续，所以用 draft 小样做检查点，而不是冻结采样。

## 5. 常用 VS Code 任务

| 任务 | 作用 |
|---|---|
| `B65: Control panel` | 打开原生 Windows 控制台 |
| `B65: Status` | RAM / VRAM / 进程状态 |
| `B65: Doctor` | 环境自检 |
| `B65: LLM Start` / `LLM Stop` | 启停 LLM |
| `B65: Video Start` / `Video Stop` | 启停 ComfyUI |
| `B65: Mode LLM` / `Mode Video` | 独占切换（停掉另一个） |
| `B65: Watch downloads` | 实时下载速度 / ETA |
| `B65: GPU temperature` | B65 温度（首次会弹 UAC） |
| `B65: Render (draft or final)` | 命令行渲染 |
| `B65: Validate workflow` | 校验工作流节点/输入 |

## 6. 手动启动面板（F5 不生效时）

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\app\B65Panel.ps1
```

`-STA` 必须保留，WinForms 需要单线程单元。

## 7. 常见问题

**F5 没有反应 / 没有 `B65: Launch control panel`**

- 安装 PowerShell 扩展；
- 右下角选择 **Windows PowerShell**（不是 PowerShell 7）；
- 重新加载窗口：`Developer: Reload Window`。

**`running scripts is disabled on this system`**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**面板打开但按钮没反应**

- 看底部 **ACTIVITY LOG** 是否出现“启动：…”；
- 看 `runtime\logs\panel-*.err.log`；
- 先在终端验证同一个命令，例如 `.\b65.ps1 doctor`。

**提示模型缺失**

```powershell
.\b65.ps1 downloads
.\b65.ps1 models -Profile draft
```

**LLM 和视频能同时跑吗？**

不能。32 GB 显存一次只装一套工作集；面板的“启动 LLM”会先停 ComfyUI，反之亦然。

## 8. 目录说明

```text
b65.ps1                 命令入口
app/B65Panel.ps1        WinForms 控制台
scripts/                所有 PowerShell 实现
workflows/              ComfyUI API 工作流
config/                 端口、模型、watchdog 配置
projects/iot-demo/      卡片与清单示例
docs/                   安装、操作、iGPU、面板文档
B65 Panel.cmd           双击启动面板
```

更多细节：[docs/00-panel.md](docs/00-panel.md)、[README.md](README.md)。
