#requires -Version 5.1
# B65Panel.ps1 - WinForms control panel for the B65 LLM + text-to-video workbench.
[CmdletBinding()]
param([string]$Tab = 'LLM', [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:Root 'scripts\B65.psm1') -Force
$script:B65 = Join-Path $script:Root 'b65.ps1'
$script:LogDir = Join-Path $script:Root 'runtime\logs'
$script:Cwd = $script:Root
$script:Busy = $false
$script:Action = $null
$script:TermProc = $null
$script:DraftPath = $null
$script:FinalPath = $null
$script:PreviewImage = $null
$script:History = New-Object System.Collections.Generic.List[string]
$script:HistoryIndex = -1

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$script:Bg = C '#0b1220'
$script:PanelBg = C '#111827'
$script:Card = C '#1e293b'
$script:Text = C '#e2e8f0'
$script:Muted = C '#94a3b8'
$script:Accent = C '#38bdf8'
$script:Green = C '#22c55e'
$script:Red = C '#ef4444'
$script:Yellow = C '#f59e0b'
$script:FontName = 'Segoe UI'

function New-Lbl {
    param(
        [string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 20,
        [double]$Size = 9, [bool]$Bold = $false, [System.Drawing.Color]$Color = $script:Text
    )
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font($script:FontName, $Size, $style)
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-Btn {
    param(
        [string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 32,
        [System.Drawing.Color]$Color = $script:Accent, [scriptblock]$OnClick = $null
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.BackColor = $Color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-Txt {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Multiline = $false)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, $H)
    $t.BackColor = C '#0b1220'
    $t.ForeColor = $script:Text
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $t.Font = New-Object System.Drawing.Font($script:FontName, 9)
    if ($Multiline) {
        $t.Multiline = $true
        $t.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $t.AcceptsReturn = $true
    }
    return $t
}

function New-Card {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y)
    $p.Size = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $script:Card
    $p.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $t = New-Lbl -Text $Title -X 12 -Y 8 -W ($W - 24) -H 20 -Size 10 -Bold $true -Color $script:Accent
    $p.Controls.Add($t)
    return $p
}

function New-LogBox {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $r = New-Object System.Windows.Forms.RichTextBox
    $r.Location = New-Object System.Drawing.Point($X, $Y)
    $r.Size = New-Object System.Drawing.Size($W, $H)
    $r.BackColor = C '#050a14'
    $r.ForeColor = C '#cbd5e1'
    $r.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $r.ReadOnly = $true
    $r.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $r.WordWrap = $false
    $r.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    return $r
}

function Add-Log {
    param([string]$Text)
    if (-not $script:MainLog) { return }
    $line = '[{0}] {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $Text, [Environment]::NewLine
    $script:MainLog.AppendText($line)
    $script:MainLog.SelectionStart = $script:MainLog.TextLength
    $script:MainLog.ScrollToCaret()
}

function Set-Status {
    param([string]$Text, [bool]$Busy = $false)
    if ($script:StatusText) { $script:StatusText.Text = $Text }
    if ($script:Bar) {
        $script:Bar.Visible = $Busy
        $script:Bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
}

function Find-Latest {
    param([string]$Pattern)
    $dir = Join-Path $script:Root 'output\shots'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $f = Get-ChildItem -LiteralPath $dir -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Show-Preview {
    param([string]$Video, $Box)
    if (-not $Video -or -not (Test-Path -LiteralPath $Video)) { return }
    $ff = Get-B65Ffmpeg
    if (-not $ff) { return }
    $png = Join-Path $script:Root 'output\shots\panel-preview.png'
    & $ff -y -v error -ss 0.5 -i $Video -frames:v 1 $png 2>$null
    if (Test-Path -LiteralPath $png) {
        $bytes = [System.IO.File]::ReadAllBytes($png)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        if ($Box.Image) { $Box.Image.Dispose() }
        $Box.Image = $img
        $script:PreviewImage = $img
    }
}

function Start-Action {
    param([string]$Label, [string[]]$ActionArgs, [scriptblock]$OnDone = $null)
    if ($script:Busy) {
        Add-Log "另一个任务正在运行：$($script:BusyLabel)"
        return
    }
    $script:Busy = $true
    $script:BusyLabel = $Label
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $script:LogDir ("panel-$stamp.out.log")
    $err = Join-Path $script:LogDir ("panel-$stamp.err.log")
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:B65 + '"'))
    foreach ($a in $ActionArgs) {
        $s = [string]$a
        if ($s -match '\s') { $argList += ('"' + $s + '"') } else { $argList += $s }
    }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $script:Root `
        -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $script:Action = [pscustomobject]@{
        Proc = $p; Out = $out; Err = $err; Done = $OnDone; Label = $Label; Start = Get-Date
    }
    $script:ActionTimer.Start()
    Set-Status $Label $true
    Add-Log "启动：$Label"
}

function Stop-Action {
    if (-not $script:Action) { return }
    try {
        & taskkill.exe /PID $script:Action.Proc.Id /T /F 2>$null | Out-Null
        Add-Log "已请求停止：$($script:Action.Label)"
    } catch {
        Add-Log "停止失败：$($_.Exception.Message)"
    }
}

function Update-Action {
    $act = $script:Action
    if (-not $act) { $script:ActionTimer.Stop(); return }
    if (Test-Path -LiteralPath $act.Out) {
        try {
            $tail = Get-Content -LiteralPath $act.Out -Tail 120 -ErrorAction SilentlyContinue | Out-String
            if ($tail) {
                $script:ActionLog.Text = $tail
                $script:ActionLog.SelectionStart = $script:ActionLog.TextLength
                $script:ActionLog.ScrollToCaret()
            }
        } catch { }
    }
    $exited = $false
    try { $exited = $act.Proc.HasExited } catch { $exited = $true }
    if (-not $exited) { return }

    $script:ActionTimer.Stop()
    $code = 0
    try { $code = $act.Proc.ExitCode } catch { }
    if (Test-Path -LiteralPath $act.Err) {
        $errText = (Get-Content -LiteralPath $act.Err -Raw -ErrorAction SilentlyContinue)
        if ($errText -and $errText.Trim()) { Add-Log ("stderr: " + $errText.Trim()) }
    }
    Add-Log ("完成：{0}（exit {1}）" -f $act.Label, $code)
    $script:Busy = $false
    $script:BusyLabel = ''
    Set-Status '就绪' $false
    $done = $act.Done
    $script:Action = $null
    if ($done) { & $done $code }
}

function Pick-Image {
    param($Box)
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Images|*.png;*.jpg;*.jpeg;*.webp;*.bmp|All files|*.*'
    $d.InitialDirectory = Join-Path $script:Root 'assets\products'
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Box.Text = $d.FileName }
}

function Start-RenderJob {
    param(
        [string]$Profile, [string]$Image, [string]$Prompt,
        [int]$Width, [int]$Height, [int]$Frames, [int]$Steps,
        [string]$Name, [int]$Seed = -1, [scriptblock]$OnDone = $null
    )
    if (-not $Image) { Add-Log '请先选择产品图。'; return }
    $img = Resolve-B65Path -Path $Image
    if (-not (Test-Path -LiteralPath $img)) { Add-Log "找不到图片：$img"; return }
    if (-not $Prompt -or -not $Prompt.Trim()) { Add-Log '请输入画面描述。'; return }
    $job = [pscustomobject]@{
        profile = $Profile; image = $img; prompt = $Prompt
        width = $Width; height = $Height; frames = $Frames; steps = $Steps
        name = $Name; createdAt = (Get-Date).ToString('o')
    }
    if ($Seed -ge 0) { $job | Add-Member -NotePropertyName seed -NotePropertyValue $Seed }
    $jobPath = Join-Path $script:Root ("runtime\panel-$Name.json")
    Write-B65Json -Path $jobPath -Value $job
    Start-Action -Label ("{0} 渲染（{1}）" -f $Profile, $Name) -ActionArgs @('render', '-JobFile', $jobPath) -OnDone $OnDone
}

function Start-Llm { Start-Action -Label '启动 LLM' -ActionArgs @('llm', 'start') }
function Stop-Llm { Start-Action -Label '停止 LLM' -ActionArgs @('llm', 'stop') }
function Restart-Llm { Start-Action -Label '重启 LLM' -ActionArgs @('llm', 'restart') }
function Start-Video { Start-Action -Label '启动 ComfyUI' -ActionArgs @('video', 'start') }
function Stop-Video { Start-Action -Label '停止 ComfyUI' -ActionArgs @('video', 'stop') }
function Open-Llm {
    $port = if ($script:LastLlmPort) { [int]$script:LastLlmPort } else { 8095 }
    if (Test-B65Port -Port $port) { Start-Process ("http://127.0.0.1:{0}" -f $port) }
    else { Add-Log "LLM 未运行（端口 $port 未监听）。" }
}
function Open-Video { if (Test-B65Port -Port 8188) { Start-Process 'http://127.0.0.1:8188' } else { Add-Log 'ComfyUI 未运行。' } }

function Cancel-Render {
    try {
        Invoke-B65Comfy -Path '/interrupt' -Method Post -TimeoutSec 10 | Out-Null
        Add-Log '已发送 interrupt。'
    } catch {
        Add-Log "interrupt 失败：$($_.Exception.Message)"
    }
}

function Get-ModelKey([string]$Name) {
    if ($Name -match 'iq3_s') { return 'IQ3_S' }
    if ($Name -match 'iq3_xxs') { return 'IQ3_XXS' }
    return 'IQ2_XS'
}

function Update-ModelInfo {
    if (-not $script:ModelCombo) { return }
    $m = [string]$script:ModelCombo.SelectedItem
    if (-not $m) { return }
    $cfg = Get-B65Config -Name llm
    $p = if ($cfg.modelCatalog) { $cfg.modelCatalog.$m } else { $null }
    if ($p) {
        $size = if ($p.sizeGB) { [string]$p.sizeGB } else { '?' }
        $script:ModelInfo.Text = ('{0}  |  ~{1} GB RAM  |  {2} GB download  |  ctx={3} lowRam={4}  |  {5}' -f $p.label, $p.ramGB, $size, $cfg.context, $cfg.lowRam, $p.note)
    } else {
        $script:ModelInfo.Text = $m
    }
}

function Update-Status {
    try {
        $st = Get-B65Status
    } catch {
        return
    }
    $script:ValMode.Text = ([string]$st.mode).ToUpper()
    $script:LastSetup = $st.llm.setup
    if ($st.llm.setup) {
        $script:ValLlm.Text = 'SETUP ' + $st.llm.setup.model
        $script:ValLlm.ForeColor = $script:Yellow
    } elseif ($st.llm.running) {
        $script:ValLlm.Text = 'RUNNING :' + $st.llm.port
        $script:ValLlm.ForeColor = $script:Green
    } else {
        $script:ValLlm.Text = 'stopped'
        $script:ValLlm.ForeColor = $script:Muted
    }
    $script:ValVideo.Text = if ($st.video.running) { 'RUNNING :' + $st.video.port } else { 'stopped' }
    $script:ValVideo.ForeColor = if ($st.video.running) { $script:Green } else { $script:Muted }
    $script:ValRam.Text = ('{0} / {1} GB' -f $st.memory.FreeGB, $st.memory.TotalGB)
    $script:ValVram.Text = ('{0} MB' -f $st.gpu.DedicatedMB)
    $script:ValWatch.Text = if ($st.watchdog -and $null -ne $st.watchdog.freeGB) { ('free {0} GB' -f $st.watchdog.freeGB) } else { 'n/a' }

    $script:LlmPid.Text = [string]$st.llm.pid
    $script:LlmPort.Text = if ($st.llm.running) { [string]$st.llm.port } else { '-' }
    $llmCfg = Get-B65Config -Name llm
    $script:LlmModel.Text = if ($st.llm.model) { [string]$st.llm.model } else { [string]$llmCfg.model }
    $script:LlmCtx.Text = if ($st.llm.context) { [string]$st.llm.context } else { [string]$llmCfg.context }
    if ($script:ModelCombo -and -not $script:ModelCombo.Focused) {
        $currentModel = if ($st.llm.running -and $st.llm.model) { [string]$st.llm.model } else { [string]$llmCfg.model }
        $key = Get-ModelKey $currentModel
        if ([string]$script:ModelCombo.SelectedItem -ne $key) { $script:ModelCombo.SelectedItem = $key }
    }
    $script:LlmRss.Text = if ($st.llm.stats -and $st.llm.stats.rssMB) { ('{0} MB' -f $st.llm.stats.rssMB) } else { '-' }
    $script:LlmVram.Text = ('{0} MB' -f $st.llm.vramMB)
    $script:VideoPid.Text = [string]$st.video.pid
    $script:VideoPort.Text = [string]$st.video.port
    $script:VideoVram.Text = ('{0} MB' -f $st.video.vramMB)
    if ($st.llm.running) {
        $script:LastLlmPort = [int]$st.llm.port
        $script:ApiUrl.Text = 'http://{0}:{1}/v1' -f $st.lanIp, $st.llm.port
        $script:ApiKey.Text = if ($st.llm.apiKey) { [string]$st.llm.apiKey } else { '(none)' }
    } else {
        $script:LastLlmPort = 0
        $script:ApiUrl.Text = if ($st.llm.setup) { '（模型下载/准备中，尚未提供 API）' } else { '(LLM stopped)' }
        $script:ApiKey.Text = '(none)'
    }
}

function Refresh-LogList {
    $files = Get-ChildItem -LiteralPath $script:LogDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    $current = $script:LogCombo.Text
    $script:LogCombo.Items.Clear()
    foreach ($f in $files) { [void]$script:LogCombo.Items.Add($f.Name) }
    if ($current -and $script:LogCombo.Items.Contains($current)) {
        $script:LogCombo.Text = $current
    } elseif ($script:LogCombo.Items.Count -gt 0) {
        $script:LogCombo.SelectedIndex = 0
    }
}

function Show-Log {
    $name = $script:LogCombo.Text
    if (-not $name) { return }
    $path = Join-Path $script:LogDir $name
    if (-not (Test-Path -LiteralPath $path)) { return }
    $text = Get-Content -LiteralPath $path -Tail 400 -ErrorAction SilentlyContinue | Out-String
    $script:LogView.Text = $text
    $script:LogView.SelectionStart = $script:LogView.TextLength
    $script:LogView.ScrollToCaret()
}

function Run-Terminal {
    if ($script:TermProc) { return }
    $cmd = $script:TermInput.Text.Trim()
    if (-not $cmd) { return }
    $script:TermInput.Text = ''
    $script:History.Add($cmd)
    $script:HistoryIndex = $script:History.Count
    $script:TermOut.AppendText("PS $($script:Cwd)> $cmd`r`n")
    if ($cmd -match '^\s*clear\s*$') { $script:TermOut.Clear(); return }
    if ($cmd -match '^\s*cd\s+(.+)$') {
        $p = $Matches[1].Trim().Trim('"')
        $new = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $script:Cwd $p }
        if (Test-Path -LiteralPath $new) {
            $script:Cwd = (Get-Item -LiteralPath $new).FullName
            $script:TermCwd.Text = $script:Cwd
        } else {
            $script:TermOut.AppendText("cd: 路径不存在：$new`r`n")
        }
        return
    }
    $stamp = Get-Date -Format 'HHmmssfff'
    $tmp = Join-Path $env:TEMP ("b65-term-$stamp.ps1")
    $out = Join-Path $env:TEMP ("b65-term-$stamp.out")
    $err = Join-Path $env:TEMP ("b65-term-$stamp.err")
    Set-Content -LiteralPath $tmp -Value $cmd -Encoding UTF8
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp) `
        -WorkingDirectory $script:Cwd -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $script:TermProc = [pscustomobject]@{ Proc = $p; Out = $out; Err = $err; Script = $tmp }
    $script:TermTimer.Start()
}

function Update-Terminal {
    $t = $script:TermProc
    if (-not $t) { $script:TermTimer.Stop(); return }
    $exited = $false
    try { $exited = $t.Proc.HasExited } catch { $exited = $true }
    if (-not $exited) { return }
    $script:TermTimer.Stop()
    $outText = if (Test-Path -LiteralPath $t.Out) { Get-Content -LiteralPath $t.Out -Raw -ErrorAction SilentlyContinue } else { '' }
    $errText = if (Test-Path -LiteralPath $t.Err) { Get-Content -LiteralPath $t.Err -Raw -ErrorAction SilentlyContinue } else { '' }
    if ($outText) { $script:TermOut.AppendText($outText.TrimEnd() + "`r`n") }
    if ($errText) { $script:TermOut.AppendText($errText.TrimEnd() + "`r`n") }
    $script:TermOut.AppendText("exit=$($t.Proc.ExitCode)`r`n`r`n")
    $script:TermOut.SelectionStart = $script:TermOut.TextLength
    $script:TermOut.ScrollToCaret()
    Remove-Item -LiteralPath $t.Script, $t.Out, $t.Err -Force -ErrorAction SilentlyContinue
    $script:TermProc = $null
}

function Open-Config([string]$Name) {
    $p = Join-Path $script:Root ('config\' + $Name)
    if (Test-Path -LiteralPath $p) { Start-Process notepad.exe -ArgumentList ('"' + $p + '"') }
    else { Add-Log "配置不存在：$p" }
}

function Open-Folder([string]$Rel) {
    $p = Join-Path $script:Root $Rel
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') }
    else { Add-Log "目录不存在：$p" }
}

# ---------------- form ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'B65 Workbench - LLM + Text-to-Video'
$form.StartPosition = 'CenterScreen'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object System.Drawing.Size([Math]::Min(1280, $wa.Width - 40), [Math]::Min(860, $wa.Height - 40))
$form.MinimumSize = New-Object System.Drawing.Size(1080, 700)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(
    ($wa.X + [Math]::Max(0, [int](($wa.Width - $form.Width) / 2))),
    ($wa.Y + [Math]::Max(0, [int](($wa.Height - $form.Height) / 2))))
$form.BackColor = $script:Bg
$form.ForeColor = $script:Text
$form.Font = New-Object System.Drawing.Font($script:FontName, 9)

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'
$top.Height = 84
$top.BackColor = $script:PanelBg
$form.Controls.Add($top)

$top.Controls.Add((New-Lbl -Text 'B65 Workbench' -X 16 -Y 8 -W 330 -H 30 -Size 17 -Bold $true -Color $script:Text))
$top.Controls.Add((New-Lbl -Text 'LLM 与文生视频的一体化控制台' -X 18 -Y 42 -W 340 -H 18 -Size 9 -Color $script:Muted))

function New-Stat {
    param($Parent, [string]$Caption, [int]$X, [int]$W)
    $cap = New-Lbl -Text $Caption -X $X -Y 8 -W $W -H 14 -Size 7.5 -Color $script:Muted
    $val = New-Lbl -Text '-' -X $X -Y 24 -W $W -H 26 -Size 11 -Bold $true -Color $script:Text
    $Parent.Controls.Add($cap)
    $Parent.Controls.Add($val)
    return $val
}

$script:ValMode = New-Stat $top 'MODE' 360 90
$script:ValLlm = New-Stat $top 'LLM' 460 130
$script:ValVideo = New-Stat $top 'VIDEO' 600 130
$script:ValRam = New-Stat $top 'RAM FREE' 740 110
$script:ValVram = New-Stat $top 'VRAM' 860 90
$script:ValWatch = New-Stat $top 'WATCHDOG' 960 120

$btnDoctor = New-Btn -Text 'Doctor' -X 1090 -Y 14 -W 120 -H 30 -Color (C '#334155') -OnClick {
    Start-Action -Label 'Doctor' -ActionArgs @('doctor')
}
$btnDash = New-Btn -Text 'Dashboard' -X 1090 -Y 50 -W 120 -H 30 -Color (C '#334155') -OnClick {
    Start-Action -Label 'Dashboard' -ActionArgs @('dashboard')
}
$top.Controls.Add($btnDoctor)
$top.Controls.Add($btnDash)

# bottom log
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = 'Bottom'
$logPanel.Height = 80
$logPanel.BackColor = $script:PanelBg
$form.Controls.Add($logPanel)
$logPanel.Controls.Add((New-Lbl -Text 'ACTIVITY LOG' -X 12 -Y 4 -W 300 -H 16 -Size 8 -Bold $true -Color $script:Accent))
$script:ActionLog = New-LogBox -X 12 -Y 22 -W 1200 -H 54
$script:ActionLog.Anchor = 'Top,Bottom,Left,Right'
$logPanel.Controls.Add($script:ActionLog)
$script:MainLog = $script:ActionLog

# status strip
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = 'Bottom'
$statusPanel.Height = 24
$statusPanel.BackColor = C '#0f172a'
$form.Controls.Add($statusPanel)
$script:StatusText = New-Lbl -Text '就绪' -X 12 -Y 3 -W 600 -H 18 -Size 9 -Color $script:Muted
$statusPanel.Controls.Add($script:StatusText)
$script:Bar = New-Object System.Windows.Forms.ProgressBar
$script:Bar.Location = New-Object System.Drawing.Point(760, 3)
$script:Bar.Size = New-Object System.Drawing.Size(260, 16)
$script:Bar.Style = 'Marquee'
$script:Bar.Visible = $false
$statusPanel.Controls.Add($script:Bar)
$btnStopAction = New-Btn -Text '停止当前任务' -X 1035 -Y 0 -W 130 -H 22 -Color $script:Red -OnClick { Stop-Action }
$statusPanel.Controls.Add($btnStopAction)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = New-Object System.Drawing.Font($script:FontName, 9.5)
$form.Controls.Add($tabs)
$tabs.BringToFront()

# ---------------- LLM tab ----------------
$llm = New-Object System.Windows.Forms.TabPage
$llm.Text = '  LLM  '
$llm.BackColor = $script:Bg
$llm.AutoScroll = $true
$tabs.TabPages.Add($llm)

$svc = New-Card -X 12 -Y 12 -W 580 -H 250 -Title 'Qwen3.8-Flash-Next / XeStrata'
$svc.Controls.Add((New-Lbl -Text '模型' -X 14 -Y 42 -W 80 -H 20 -Color $script:Muted))
$script:LlmModel = New-Lbl -Text '-' -X 100 -Y 42 -W 450 -H 20 -Bold $true
$svc.Controls.Add($script:LlmModel)
$svc.Controls.Add((New-Lbl -Text '上下文' -X 14 -Y 70 -W 80 -H 20 -Color $script:Muted))
$script:LlmCtx = New-Lbl -Text '-' -X 100 -Y 70 -W 200 -H 20
$svc.Controls.Add($script:LlmCtx)
$svc.Controls.Add((New-Lbl -Text '端口' -X 14 -Y 98 -W 80 -H 20 -Color $script:Muted))
$script:LlmPort = New-Lbl -Text '-' -X 100 -Y 98 -W 200 -H 20
$svc.Controls.Add($script:LlmPort)
$svc.Controls.Add((New-Lbl -Text 'PID' -X 14 -Y 126 -W 80 -H 20 -Color $script:Muted))
$script:LlmPid = New-Lbl -Text '-' -X 100 -Y 126 -W 200 -H 20
$svc.Controls.Add($script:LlmPid)
$svc.Controls.Add((New-Lbl -Text 'RSS' -X 14 -Y 154 -W 80 -H 20 -Color $script:Muted))
$script:LlmRss = New-Lbl -Text '-' -X 100 -Y 154 -W 200 -H 20
$svc.Controls.Add($script:LlmRss)
$svc.Controls.Add((New-Lbl -Text '显存' -X 14 -Y 182 -W 80 -H 20 -Color $script:Muted))
$script:LlmVram = New-Lbl -Text '-' -X 100 -Y 182 -W 200 -H 20
$svc.Controls.Add($script:LlmVram)

$svc.Controls.Add((New-Btn -Text '加载 / 启动' -X 14 -Y 208 -W 130 -H 32 -Color $script:Green -OnClick { Start-Llm }))
$svc.Controls.Add((New-Btn -Text '卸载 / 停止' -X 152 -Y 208 -W 130 -H 32 -Color $script:Red -OnClick { Stop-Llm }))
$svc.Controls.Add((New-Btn -Text '重启' -X 290 -Y 208 -W 100 -H 32 -Color (C '#334155') -OnClick { Restart-Llm }))
$svc.Controls.Add((New-Btn -Text '打开 API' -X 398 -Y 208 -W 110 -H 32 -Color $script:Accent -OnClick { Open-Llm }))
$llm.Controls.Add($svc)

$api = New-Card -X 12 -Y 266 -W 580 -H 180 -Title 'LAN API'
$api.Controls.Add((New-Lbl -Text 'Base URL' -X 14 -Y 42 -W 80 -H 20 -Color $script:Muted))
$script:ApiUrl = New-Lbl -Text '-' -X 100 -Y 42 -W 460 -H 20 -Bold $true
$api.Controls.Add($script:ApiUrl)
$api.Controls.Add((New-Lbl -Text 'API Key' -X 14 -Y 70 -W 80 -H 20 -Color $script:Muted))
$script:ApiKey = New-Lbl -Text '(none)' -X 100 -Y 70 -W 460 -H 20
$api.Controls.Add($script:ApiKey)
$api.Controls.Add((New-Btn -Text '复制 Base URL' -X 14 -Y 104 -W 140 -H 32 -Color (C '#334155') -OnClick {
    [System.Windows.Forms.Clipboard]::SetText($script:ApiUrl.Text); Add-Log '已复制 Base URL'
}))
$api.Controls.Add((New-Btn -Text '复制 API Key' -X 162 -Y 104 -W 140 -H 32 -Color (C '#334155') -OnClick {
    [System.Windows.Forms.Clipboard]::SetText($script:ApiKey.Text); Add-Log '已复制 API Key'
}))
$api.Controls.Add((New-Lbl -Text '提示：加载 LLM 前会先停掉 ComfyUI，32 GB 显存一次只跑一项。' -X 14 -Y 148 -W 540 -H 30 -Size 8.5 -Color $script:Muted))
$llm.Controls.Add($api)
$modelCard = New-Card -X 12 -Y 456 -W 580 -H 140 -Title '模型档位'
$modelCard.Controls.Add((New-Lbl -Text '模型' -X 14 -Y 40 -W 50 -H 20 -Color $script:Muted))
$script:ModelCombo = New-Object System.Windows.Forms.ComboBox
$script:ModelCombo.Location = New-Object System.Drawing.Point(64, 36)
$script:ModelCombo.Size = New-Object System.Drawing.Size(180, 24)
$script:ModelCombo.DropDownStyle = 'DropDownList'
$script:ModelCombo.BackColor = C '#0b1220'
$script:ModelCombo.ForeColor = $script:Text
[void]$script:ModelCombo.Items.AddRange(@('IQ3_XXS', 'IQ3_S', 'IQ2_XS'))
$script:ModelCombo.SelectedItem = 'IQ2_XS'
$script:ModelCombo.Add_SelectedIndexChanged({ Update-ModelInfo })
$modelCard.Controls.Add($script:ModelCombo)
$script:ModelInfo = New-Lbl -Text '' -X 14 -Y 66 -W 540 -H 30 -Size 8.5 -Color $script:Muted
$modelCard.Controls.Add($script:ModelInfo)
$modelCard.Controls.Add((New-Btn -Text '应用并重启' -X 14 -Y 100 -W 130 -H 30 -Color $script:Green -OnClick {
    $m = [string]$script:ModelCombo.SelectedItem
    Start-Action -Label ("切换到 $m") -ActionArgs @('llm', 'switch', '-Model', $m)
}))
$modelCard.Controls.Add((New-Btn -Text '下载 / 更新' -X 152 -Y 100 -W 120 -H 30 -Color $script:Accent -OnClick {
    if ($script:LastSetup) { Add-Log "已有模型下载/准备任务在运行：$($script:LastSetup.model)"; return }
    $m = [string]$script:ModelCombo.SelectedItem
    Start-Action -Label ("下载 $m") -ActionArgs @('install', 'llm', '-Model', $m, '-RunSetup', '-NoStart', '-SetDefault')
}))
$modelCard.Controls.Add((New-Btn -Text '选项...' -X 280 -Y 100 -W 90 -H 30 -Color (C '#334155') -OnClick {
    Open-Config 'llm.json'
    Add-Log '在 llm.json 修改 context / lowRam / kv / maxOutputTokens 后，点“应用并重启”。'
}))
$modelCard.Controls.Add((New-Btn -Text '刷新档位' -X 378 -Y 100 -W 90 -H 30 -Color (C '#334155') -OnClick { Update-ModelInfo }))
$llm.Controls.Add($modelCard)
Update-ModelInfo


$help = New-Card -X 606 -Y 12 -W 580 -H 434 -Title '工作方式'
$helpText = @"
1. 点“加载 / 启动”：XeStrata 加载 IQ2_XS 到 B65；API 端口以本页“端口 / Base URL”为准（可能不是 8095）。
2. 第一次加载会建立专家缓存，耗时较长；看下方 ACTIVITY LOG。
3. “卸载 / 停止”会释放显存，再切到视频。
4. API 兼容 OpenAI：POST /v1/chat/completions。
5. 如果系统内存低于 watchdog 阈值，会自动停止 LLM。
6. 配置在 config\llm.json，改完点“重启”。
"@
$help.Controls.Add((New-Lbl -Text $helpText -X 14 -Y 40 -W 548 -H 250 -Size 9 -Color $script:Text))
$help.Controls.Add((New-Btn -Text '编辑 llm.json' -X 14 -Y 300 -W 150 -H 32 -Color (C '#334155') -OnClick { Open-Config 'llm.json' }))
$help.Controls.Add((New-Btn -Text '打开日志目录' -X 174 -Y 300 -W 150 -H 32 -Color (C '#334155') -OnClick { Open-Folder 'runtime\logs' }))
$llm.Controls.Add($help)

# ---------------- Video tab ----------------
$video = New-Object System.Windows.Forms.TabPage
$video.Text = '  视频  '
$video.BackColor = $script:Bg
$video.AutoScroll = $true
$tabs.TabPages.Add($video)

$comfy = New-Card -X 12 -Y 12 -W 580 -H 140 -Title 'ComfyUI / Wan2.2'
$comfy.Controls.Add((New-Lbl -Text '状态' -X 14 -Y 38 -W 80 -H 20 -Color $script:Muted))
$script:VideoState = New-Lbl -Text 'stopped' -X 100 -Y 38 -W 300 -H 20 -Bold $true
$comfy.Controls.Add($script:VideoState)
$comfy.Controls.Add((New-Lbl -Text 'PID' -X 14 -Y 62 -W 80 -H 20 -Color $script:Muted))
$script:VideoPid = New-Lbl -Text '-' -X 100 -Y 62 -W 200 -H 20
$comfy.Controls.Add($script:VideoPid)
$comfy.Controls.Add((New-Lbl -Text '端口' -X 14 -Y 84 -W 80 -H 20 -Color $script:Muted))
$script:VideoPort = New-Lbl -Text '-' -X 100 -Y 84 -W 200 -H 20
$comfy.Controls.Add($script:VideoPort)
$comfy.Controls.Add((New-Lbl -Text '显存' -X 300 -Y 62 -W 60 -H 20 -Color $script:Muted))
$script:VideoVram = New-Lbl -Text '-' -X 360 -Y 62 -W 160 -H 20
$comfy.Controls.Add($script:VideoVram)
$comfy.Controls.Add((New-Btn -Text '启动' -X 14 -Y 106 -W 100 -H 32 -Color $script:Green -OnClick { Start-Video }))
$comfy.Controls.Add((New-Btn -Text '停止' -X 122 -Y 106 -W 100 -H 32 -Color $script:Red -OnClick { Stop-Video }))
$comfy.Controls.Add((New-Btn -Text '打开 ComfyUI' -X 230 -Y 106 -W 140 -H 32 -Color $script:Accent -OnClick { Open-Video }))
$video.Controls.Add($comfy)

$quick = New-Card -X 12 -Y 160 -W 580 -H 330 -Title '快速渲染'
$quick.Controls.Add((New-Lbl -Text '档位' -X 14 -Y 36 -W 60 -H 20 -Color $script:Muted))
$script:QuickProfile = New-Object System.Windows.Forms.ComboBox
$script:QuickProfile.Location = New-Object System.Drawing.Point(80, 34)
$script:QuickProfile.Size = New-Object System.Drawing.Size(120, 24)
$script:QuickProfile.DropDownStyle = 'DropDownList'
[void]$script:QuickProfile.Items.AddRange(@('draft', 'final'))
$script:QuickProfile.SelectedIndex = 0
$quick.Controls.Add($script:QuickProfile)
$quick.Controls.Add((New-Lbl -Text '产品图' -X 14 -Y 64 -W 60 -H 20 -Color $script:Muted))
$script:QuickImage = New-Txt -X 80 -Y 62 -W 400 -H 24
$quick.Controls.Add($script:QuickImage)
$quick.Controls.Add((New-Btn -Text '浏览' -X 488 -Y 61 -W 76 -H 26 -Color (C '#334155') -OnClick { Pick-Image $script:QuickImage }))
$quick.Controls.Add((New-Lbl -Text '描述' -X 14 -Y 92 -W 60 -H 20 -Color $script:Muted))
$script:QuickPrompt = New-Txt -X 80 -Y 90 -W 484 -H 80 -Multiline $true
$quick.Controls.Add($script:QuickPrompt)
$quick.Controls.Add((New-Lbl -Text '宽' -X 14 -Y 184 -W 20 -H 20 -Color $script:Muted))
$script:QuickW = New-Object System.Windows.Forms.NumericUpDown
$script:QuickW.Location = New-Object System.Drawing.Point(38, 182); $script:QuickW.Size = New-Object System.Drawing.Size(70, 24)
$script:QuickW.Minimum = 256; $script:QuickW.Maximum = 1920; $script:QuickW.Value = 832; $script:QuickW.Increment = 16
$quick.Controls.Add($script:QuickW)
$quick.Controls.Add((New-Lbl -Text '高' -X 120 -Y 184 -W 20 -H 20 -Color $script:Muted))
$script:QuickH = New-Object System.Windows.Forms.NumericUpDown
$script:QuickH.Location = New-Object System.Drawing.Point(144, 182); $script:QuickH.Size = New-Object System.Drawing.Size(70, 24)
$script:QuickH.Minimum = 256; $script:QuickH.Maximum = 1920; $script:QuickH.Value = 480; $script:QuickH.Increment = 16
$quick.Controls.Add($script:QuickH)
$quick.Controls.Add((New-Lbl -Text '帧' -X 226 -Y 184 -W 20 -H 20 -Color $script:Muted))
$script:QuickF = New-Object System.Windows.Forms.NumericUpDown
$script:QuickF.Location = New-Object System.Drawing.Point(250, 182); $script:QuickF.Size = New-Object System.Drawing.Size(70, 24)
$script:QuickF.Minimum = 17; $script:QuickF.Maximum = 257; $script:QuickF.Value = 49; $script:QuickF.Increment = 4
$quick.Controls.Add($script:QuickF)
$quick.Controls.Add((New-Lbl -Text '步' -X 332 -Y 184 -W 20 -H 20 -Color $script:Muted))
$script:QuickS = New-Object System.Windows.Forms.NumericUpDown
$script:QuickS.Location = New-Object System.Drawing.Point(356, 182); $script:QuickS.Size = New-Object System.Drawing.Size(60, 24)
$script:QuickS.Minimum = 1; $script:QuickS.Maximum = 30; $script:QuickS.Value = 4
$quick.Controls.Add($script:QuickS)
$quick.Controls.Add((New-Btn -Text '渲染' -X 14 -Y 222 -W 120 -H 34 -Color $script:Green -OnClick {
    Start-RenderJob -Profile $script:QuickProfile.Text -Image $script:QuickImage.Text -Prompt $script:QuickPrompt.Text `
        -Width ([int]$script:QuickW.Value) -Height ([int]$script:QuickH.Value) -Frames ([int]$script:QuickF.Value) `
        -Steps ([int]$script:QuickS.Value) -Name 'panel-quick' -OnDone {
            param($code)
            if ($code -eq 0) { Refresh-Outputs }
        }
}))
$quick.Controls.Add((New-Btn -Text '取消当前' -X 142 -Y 222 -W 110 -H 34 -Color $script:Yellow -OnClick { Cancel-Render }))
$quick.Controls.Add((New-Btn -Text '打开输出目录' -X 260 -Y 222 -W 140 -H 34 -Color (C '#334155') -OnClick { Open-Folder 'output\shots' }))
$quick.Controls.Add((New-Lbl -Text 'draft 适合试镜；final 是 14B + 4-step LoRA。' -X 14 -Y 270 -W 540 -H 20 -Size 8.5 -Color $script:Muted))
$video.Controls.Add($quick)

$outputs = New-Card -X 606 -Y 12 -W 580 -H 480 -Title '最近输出'
$script:OutputList = New-Object System.Windows.Forms.ListView
$script:OutputList.Location = New-Object System.Drawing.Point(14, 38)
$script:OutputList.Size = New-Object System.Drawing.Size(550, 402)
$script:OutputList.View = 'Details'
$script:OutputList.FullRowSelect = $true
$script:OutputList.BackColor = C '#0b1220'
$script:OutputList.ForeColor = $script:Text
$script:OutputList.BorderStyle = 'FixedSingle'
[void]$script:OutputList.Columns.Add('文件', 300)
[void]$script:OutputList.Columns.Add('MB', 70)
[void]$script:OutputList.Columns.Add('时间', 90)
$script:OutputList.Anchor = 'Top,Bottom,Left,Right'
$script:OutputList.Add_DoubleClick({
    if ($script:OutputList.SelectedItems.Count -gt 0) {
        $p = Join-Path $script:Root ('output\shots\' + $script:OutputList.SelectedItems[0].Text)
        if (Test-Path -LiteralPath $p) { Start-Process $p }
    }
})
$outputs.Controls.Add($script:OutputList)
$outputs.Controls.Add((New-Btn -Text '刷新' -X 470 -Y 442 -W 90 -H 26 -Color (C '#334155') -OnClick { Refresh-Outputs }))
$video.Controls.Add($outputs)

# ---------------- Workflow tab ----------------
$wf = New-Object System.Windows.Forms.TabPage
$wf.Text = '  广告工作流  '
$wf.BackColor = $script:Bg
$wf.AutoScroll = $true
$tabs.TabPages.Add($wf)

$wfInput = New-Card -X 12 -Y 12 -W 580 -H 270 -Title '1. 输入'
$wfInput.Controls.Add((New-Lbl -Text '产品图' -X 14 -Y 42 -W 60 -H 20 -Color $script:Muted))
$script:WfImage = New-Txt -X 80 -Y 40 -W 400 -H 24
$wfInput.Controls.Add($script:WfImage)
$wfInput.Controls.Add((New-Btn -Text '浏览' -X 488 -Y 39 -W 76 -H 26 -Color (C '#334155') -OnClick { Pick-Image $script:WfImage }))
$wfInput.Controls.Add((New-Lbl -Text '产品名' -X 14 -Y 74 -W 60 -H 20 -Color $script:Muted))
$script:WfName = New-Txt -X 80 -Y 72 -W 300 -H 24
$script:WfName.Text = 'IoT Module'
$wfInput.Controls.Add($script:WfName)
$wfInput.Controls.Add((New-Lbl -Text '画面描述' -X 14 -Y 106 -W 60 -H 20 -Color $script:Muted))
$script:WfPrompt = New-Txt -X 80 -Y 104 -W 484 -H 90 -Multiline $true
$script:WfPrompt.Text = 'slow dolly-in, soft rim light, dark reflective surface, no people, cinematic product shot'
$wfInput.Controls.Add($script:WfPrompt)
$script:WfPause = New-Object System.Windows.Forms.CheckBox
$script:WfPause.Text = 'draft 完成后暂停，等我检查小样再继续'
$script:WfPause.Location = New-Object System.Drawing.Point(14, 204)
$script:WfPause.Size = New-Object System.Drawing.Size(540, 24)
$script:WfPause.ForeColor = $script:Text
$script:WfPause.Checked = $true
$wfInput.Controls.Add($script:WfPause)
$wfInput.Controls.Add((New-Lbl -Text '流程：draft 小样 → 你确认 → final 14B → 合成 1080p 广告。' -X 14 -Y 234 -W 540 -H 24 -Size 8.5 -Color $script:Muted))
$wf.Controls.Add($wfInput)

$wfSteps = New-Card -X 12 -Y 290 -W 580 -H 205 -Title '2. 执行'
$wfSteps.Controls.Add((New-Btn -Text '① 生成 draft 小样' -X 14 -Y 36 -W 180 -H 38 -Color $script:Accent -OnClick { Workflow-Draft }))
$wfSteps.Controls.Add((New-Btn -Text '② 确认 → 生成 final' -X 204 -Y 36 -W 180 -H 38 -Color $script:Green -OnClick { Workflow-Final }))
$wfSteps.Controls.Add((New-Btn -Text '重新生成 draft' -X 394 -Y 36 -W 160 -H 38 -Color (C '#334155') -OnClick { Workflow-Regenerate }))
$wfSteps.Controls.Add((New-Btn -Text '③ 合成 1080p 广告' -X 14 -Y 84 -W 180 -H 38 -Color (C '#8b5cf6') -OnClick { Workflow-Build }))
$wfSteps.Controls.Add((New-Btn -Text '打开 draft' -X 204 -Y 84 -W 120 -H 38 -Color (C '#334155') -OnClick {
    if ($script:DraftPath) { Start-Process $script:DraftPath } else { Add-Log '还没有 draft。' }
}))
$wfSteps.Controls.Add((New-Btn -Text '打开 final' -X 334 -Y 84 -W 120 -H 38 -Color (C '#334155') -OnClick {
    if ($script:FinalPath) { Start-Process $script:FinalPath } else { Add-Log '还没有 final。' }
}))
$wfSteps.Controls.Add((New-Btn -Text '打开广告' -X 464 -Y 84 -W 96 -H 38 -Color (C '#334155') -OnClick {
    $p = Join-Path $script:Root 'output\panel-ad.mp4'
    if (Test-Path -LiteralPath $p) { Start-Process $p } else { Add-Log '还没有合成广告。' }
}))
$script:WfStep = New-Lbl -Text 'Step 0/4 - 选择产品图，生成 draft。' -X 14 -Y 136 -W 540 -H 24 -Bold $true -Color $script:Yellow
$wfSteps.Controls.Add($script:WfStep)
$wfSteps.Controls.Add((New-Lbl -Text 'ComfyUI 不支持渲染中途暂停；用 draft 小样做检查点。' -X 14 -Y 166 -W 540 -H 40 -Size 8.5 -Color $script:Muted))
$wf.Controls.Add($wfSteps)

$wfPreview = New-Card -X 606 -Y 12 -W 580 -H 480 -Title '预览 / 检查小样'
$script:WfPic = New-Object System.Windows.Forms.PictureBox
$script:WfPic.Location = New-Object System.Drawing.Point(14, 38)
$script:WfPic.Size = New-Object System.Drawing.Size(550, 280)
$script:WfPic.BackColor = C '#020617'
$script:WfPic.SizeMode = 'Zoom'
$script:WfPic.BorderStyle = 'FixedSingle'
$wfPreview.Controls.Add($script:WfPic)
$script:WfDraftLabel = New-Lbl -Text 'draft: -' -X 14 -Y 328 -W 550 -H 20 -Size 8.5 -Color $script:Muted
$wfPreview.Controls.Add($script:WfDraftLabel)
$script:WfFinalLabel = New-Lbl -Text 'final: -' -X 14 -Y 352 -W 550 -H 20 -Size 8.5 -Color $script:Muted
$wfPreview.Controls.Add($script:WfFinalLabel)
$wfPreview.Controls.Add((New-Btn -Text '打开 draft 视频' -X 14 -Y 382 -W 160 -H 34 -Color (C '#334155') -OnClick {
    if ($script:DraftPath) { Start-Process $script:DraftPath }
}))
$wfPreview.Controls.Add((New-Btn -Text '打开 final 视频' -X 184 -Y 382 -W 160 -H 34 -Color (C '#334155') -OnClick {
    if ($script:FinalPath) { Start-Process $script:FinalPath }
}))
$wfPreview.Controls.Add((New-Lbl -Text '建议：真实产品图、16:9、主体居中、无文字。' -X 14 -Y 430 -W 540 -H 40 -Size 8.5 -Color $script:Muted))
$wf.Controls.Add($wfPreview)

# ---------------- Logs tab ----------------
$logs = New-Object System.Windows.Forms.TabPage
$logs.Text = '  日志  '
$logs.BackColor = $script:Bg
$tabs.TabPages.Add($logs)

$script:LogCombo = New-Object System.Windows.Forms.ComboBox
$script:LogCombo.Location = New-Object System.Drawing.Point(12, 12)
$script:LogCombo.Size = New-Object System.Drawing.Size(300, 24)
$script:LogCombo.DropDownStyle = 'DropDownList'
$script:LogCombo.BackColor = C '#0b1220'
$script:LogCombo.ForeColor = $script:Text
$script:LogCombo.Add_SelectedIndexChanged({ Show-Log })
$logs.Controls.Add($script:LogCombo)
$logs.Controls.Add((New-Btn -Text '刷新列表' -X 322 -Y 11 -W 100 -H 26 -Color (C '#334155') -OnClick { Refresh-LogList; Show-Log }))
$logs.Controls.Add((New-Btn -Text '打开日志目录' -X 430 -Y 11 -W 130 -H 26 -Color (C '#334155') -OnClick { Open-Folder 'runtime\logs' }))
$script:LogAuto = New-Object System.Windows.Forms.CheckBox
$script:LogAuto.Text = '自动刷新'
$script:LogAuto.Location = New-Object System.Drawing.Point(580, 14)
$script:LogAuto.Size = New-Object System.Drawing.Size(100, 22)
$script:LogAuto.ForeColor = $script:Text
$script:LogAuto.Checked = $true
$logs.Controls.Add($script:LogAuto)
$script:LogView = New-LogBox -X 12 -Y 46 -W 1160 -H 560
$script:LogView.Anchor = 'Top,Bottom,Left,Right'
$logs.Controls.Add($script:LogView)

# ---------------- Terminal tab ----------------
$term = New-Object System.Windows.Forms.TabPage
$term.Text = '  终端  '
$term.BackColor = $script:Bg
$tabs.TabPages.Add($term)

$script:TermOut = New-Object System.Windows.Forms.RichTextBox
$script:TermOut.Location = New-Object System.Drawing.Point(12, 12)
$script:TermOut.Size = New-Object System.Drawing.Size(1160, 470)
$script:TermOut.BackColor = C '#020617'
$script:TermOut.ForeColor = C '#d1fae5'
$script:TermOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:TermOut.ReadOnly = $true
$script:TermOut.BorderStyle = 'FixedSingle'
$script:TermOut.WordWrap = $false
$script:TermOut.ScrollBars = 'Both'
$script:TermOut.Anchor = 'Top,Bottom,Left,Right'
$term.Controls.Add($script:TermOut)

$script:TermCwd = New-Lbl -Text $script:Cwd -X 12 -Y 492 -W 700 -H 18 -Size 8 -Color $script:Muted
$term.Controls.Add($script:TermCwd)
$script:TermInput = New-Txt -X 12 -Y 512 -W 1040 -H 26
$script:TermInput.Anchor = 'Bottom,Left,Right'
$script:TermInput.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $_.SuppressKeyPress = $true; Run-Terminal }
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Up -and $script:History.Count -gt 0) {
        if ($script:HistoryIndex -gt 0) { $script:HistoryIndex-- }
        $script:TermInput.Text = $script:History[$script:HistoryIndex]
        $script:TermInput.SelectionStart = $script:TermInput.TextLength
    }
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Down -and $script:History.Count -gt 0) {
        if ($script:HistoryIndex -lt ($script:History.Count - 1)) { $script:HistoryIndex++ } else { $script:HistoryIndex = $script:History.Count }
        $script:TermInput.Text = if ($script:HistoryIndex -lt $script:History.Count) { $script:History[$script:HistoryIndex] } else { '' }
    }
})
$term.Controls.Add($script:TermInput)
$term.Controls.Add((New-Btn -Text '运行' -X 1060 -Y 511 -W 110 -H 28 -Color $script:Green -OnClick { Run-Terminal }))
$term.Controls.Add((New-Btn -Text '清空' -X 1060 -Y 545 -W 110 -H 24 -Color (C '#334155') -OnClick { $script:TermOut.Clear() }))

# ---------------- Settings tab ----------------
$settings = New-Object System.Windows.Forms.TabPage
$settings.Text = '  设置  '
$settings.BackColor = $script:Bg
$settings.AutoScroll = $true
$tabs.TabPages.Add($settings)

$cfg = New-Card -X 12 -Y 12 -W 580 -H 300 -Title '配置文件'
$cfg.Controls.Add((New-Btn -Text 'llm.json' -X 14 -Y 40 -W 160 -H 32 -Color (C '#334155') -OnClick { Open-Config 'llm.json' }))
$cfg.Controls.Add((New-Btn -Text 'video.json' -X 184 -Y 40 -W 160 -H 32 -Color (C '#334155') -OnClick { Open-Config 'video.json' }))
$cfg.Controls.Add((New-Btn -Text 'settings.json' -X 354 -Y 40 -W 160 -H 32 -Color (C '#334155') -OnClick { Open-Config 'settings.json' }))
$cfg.Controls.Add((New-Btn -Text 'models.json' -X 14 -Y 80 -W 160 -H 32 -Color (C '#334155') -OnClick { Open-Config 'models.json' }))
$cfg.Controls.Add((New-Btn -Text '打开 config 目录' -X 184 -Y 80 -W 180 -H 32 -Color (C '#334155') -OnClick { Open-Folder 'config' }))
$cfg.Controls.Add((New-Btn -Text '打开项目目录' -X 374 -Y 80 -W 180 -H 32 -Color (C '#334155') -OnClick { Open-Folder '.' }))
$cfg.Controls.Add((New-Lbl -Text '改完 JSON 后：LLM 用“重启”，ComfyUI 用“停止/启动”。' -X 14 -Y 130 -W 540 -H 24 -Size 8.5 -Color $script:Muted))
$settings.Controls.Add($cfg)

$about = New-Card -X 606 -Y 12 -W 580 -H 300 -Title '关于'
$about.Controls.Add((New-Lbl -Text 'B65 Workbench' -X 14 -Y 42 -W 300 -H 24 -Size 12 -Bold $true))
$about.Controls.Add((New-Lbl -Text 'PowerShell 5.1 + WinForms，无需额外运行时。' -X 14 -Y 72 -W 540 -H 22 -Color $script:Muted))
$about.Controls.Add((New-Lbl -Text '所有动作最终调用 b65.ps1，可同时在终端里复现。' -X 14 -Y 98 -W 540 -H 22 -Color $script:Muted))
$about.Controls.Add((New-Btn -Text '打开 README' -X 14 -Y 132 -W 160 -H 32 -Color (C '#334155') -OnClick { Start-Process (Join-Path $script:Root 'README.md') }))
$about.Controls.Add((New-Btn -Text '打开 output' -X 184 -Y 132 -W 160 -H 32 -Color (C '#334155') -OnClick { Open-Folder 'output' }))
$settings.Controls.Add($about)

# ---------------- timers / functions ----------------
$script:ActionTimer = New-Object System.Windows.Forms.Timer
$script:ActionTimer.Interval = 600
$script:ActionTimer.Add_Tick({ Update-Action })

$script:StatusTimer = New-Object System.Windows.Forms.Timer
$script:StatusTimer.Interval = 3000
$script:StatusTimer.Add_Tick({ Update-Status })

$script:LogTimer = New-Object System.Windows.Forms.Timer
$script:LogTimer.Interval = 2500
$script:LogTimer.Add_Tick({
    if ($tabs.SelectedTab -eq $logs -and $script:LogAuto.Checked) { Show-Log }
})

$script:TermTimer = New-Object System.Windows.Forms.Timer
$script:TermTimer.Interval = 400
$script:TermTimer.Add_Tick({ Update-Terminal })

function Refresh-Outputs {
    if (-not $script:OutputList) { return }
    $dir = Join-Path $script:Root 'output\shots'
    $script:OutputList.Items.Clear()
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.mp4', '.webm') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 30 | ForEach-Object {
            $item = New-Object System.Windows.Forms.ListViewItem($_.Name)
            [void]$item.SubItems.Add([math]::Round($_.Length / 1MB, 1))
            [void]$item.SubItems.Add($_.LastWriteTime.ToString('HH:mm:ss'))
            [void]$script:OutputList.Items.Add($item)
        }
}

function Workflow-Draft {
    $script:WfStep.Text = 'Step 1/4 - 生成 draft 中...'
    Start-RenderJob -Profile 'draft' -Image $script:WfImage.Text -Prompt $script:WfPrompt.Text `
        -Width 832 -Height 480 -Frames 49 -Steps 4 -Name 'panel-draft' -OnDone {
            param($code)
            if ($code -ne 0) { $script:WfStep.Text = 'draft 失败，看 ACTIVITY LOG。'; return }
            $script:DraftPath = Find-Latest 'panel-draft*.mp4'
            if ($script:DraftPath) {
                Show-Preview $script:DraftPath $script:WfPic
                $script:WfDraftLabel.Text = 'draft: ' + $script:DraftPath
                $script:WfStep.Text = 'Step 2/4 - draft 完成。检查预览，满意就点“确认 → final”。'
                Add-Log ('draft: ' + $script:DraftPath)
            } else {
                $script:WfStep.Text = 'draft 完成，但没找到输出文件。'
            }
        }
}

function Workflow-Regenerate {
    $seed = Get-Random -Minimum 1 -Maximum 2147483000
    $script:WfStep.Text = 'Step 1/4 - 重新生成 draft...'
    Start-RenderJob -Profile 'draft' -Image $script:WfImage.Text -Prompt $script:WfPrompt.Text `
        -Width 832 -Height 480 -Frames 49 -Steps 4 -Name 'panel-draft' -Seed $seed -OnDone {
            param($code)
            if ($code -ne 0) { $script:WfStep.Text = 'draft 失败。'; return }
            $script:DraftPath = Find-Latest 'panel-draft*.mp4'
            if ($script:DraftPath) { Show-Preview $script:DraftPath $script:WfPic; $script:WfDraftLabel.Text = 'draft: ' + $script:DraftPath }
            $script:WfStep.Text = 'Step 2/4 - 新 draft 完成，检查预览。'
        }
}

function Workflow-Final {
    $script:WfStep.Text = 'Step 3/4 - 生成 final（14B，约 3–6 分钟）...'
    Start-RenderJob -Profile 'final' -Image $script:WfImage.Text -Prompt $script:WfPrompt.Text `
        -Width 1280 -Height 720 -Frames 121 -Steps 4 -Name 'panel-final' -OnDone {
            param($code)
            if ($code -ne 0) { $script:WfStep.Text = 'final 失败，看 ACTIVITY LOG。'; return }
            $script:FinalPath = Find-Latest 'panel-final*.mp4'
            if ($script:FinalPath) {
                Show-Preview $script:FinalPath $script:WfPic
                $script:WfFinalLabel.Text = 'final: ' + $script:FinalPath
                $script:WfStep.Text = 'Step 4/4 - final 完成，可以合成 1080p 广告。'
            }
        }
}

function Workflow-Build {
    $clip = if ($script:FinalPath) { $script:FinalPath } else { $script:DraftPath }
    if (-not $clip) { Add-Log '先渲染 draft 或 final。'; return }
    $cards = Join-Path $script:Root 'projects\iot-demo\cards'
    $scenes = @()
    if (Test-Path -LiteralPath (Join-Path $cards 'intro.json')) {
        $scenes += [pscustomobject]@{ type = 'card'; data = 'projects/iot-demo/cards/intro.json'; duration = 3 }
    }
    $scenes += [pscustomobject]@{ type = 'clip'; path = $clip; duration = 5 }
    if (Test-Path -LiteralPath (Join-Path $cards 'specs.json')) {
        $scenes += [pscustomobject]@{ type = 'card'; data = 'projects/iot-demo/cards/specs.json'; duration = 4 }
    }
    $manifest = [pscustomobject]@{
        width = 1920; height = 1080; fps = 30
        scenes = $scenes
        audio = [pscustomobject]@{ voice = ''; music = ''; musicVolume = 0.12 }
        output = 'output/panel-ad.mp4'
    }
    $path = Join-Path $script:Root 'runtime\panel-ad.json'
    Write-B65Json -Path $path -Value $manifest
    Start-Action -Label '合成广告' -ActionArgs @('build', '-Manifest', $path) -OnDone {
        param($code)
        if ($code -eq 0) {
            $out = Join-Path $script:Root 'output\panel-ad.mp4'
            if (Test-Path -LiteralPath $out) { Start-Process $out; $script:WfStep.Text = '完成：output\panel-ad.mp4' }
        }
    }
}

# ---------------- show ----------------
$form.Add_Shown({
    Refresh-LogList
    Show-Log
    Refresh-Outputs
    Update-Status
    $script:StatusTimer.Start()
    $script:LogTimer.Start()
    $tabMap = @{ 'llm' = 'LLM'; 'video' = '视频'; 'workflow' = '广告工作流'; 'logs' = '日志'; 'terminal' = '终端'; 'settings' = '设置' }
    $target = $Tab
    if ($tabMap.ContainsKey(([string]$Tab).ToLower())) { $target = $tabMap[([string]$Tab).ToLower()] }
    foreach ($tp in $tabs.TabPages) {
        if ($tp.Text.Trim() -eq $target) { $tabs.SelectedTab = $tp }
    }
    Add-Log ('B65 Workbench 已启动：' + $script:Root)
    if ($SelfTest) {
        Start-Action -Label 'SelfTest doctor' -ActionArgs @('doctor') -OnDone {
            param($code)
            Add-Log ("SelfTest finished: exit $code")
            Start-Sleep -Milliseconds 800
            $form.Close()
        }
    }
})

[void]$form.ShowDialog()
