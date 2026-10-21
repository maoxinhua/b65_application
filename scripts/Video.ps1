# Video.ps1 - start, stop, restart and inspect the ComfyUI Intel XPU engine.
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status')][string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$settings = Get-B65Config -Name settings
$videoCfg = Get-B65Config -Name video
$state = Get-B65State

function Stop-VideoInternal {
    $state = Get-B65State
    if ([int]$state.video.pid -gt 0) {
        Stop-B65Managed -ProcessId ([int]$state.video.pid) -Name 'comfy' | Out-Null
    }
    if ([int]$state.video.watchdogPid -gt 0) {
        Stop-B65Managed -ProcessId ([int]$state.video.watchdogPid) -Name 'comfy-watchdog' -WaitSec 5 | Out-Null
    }
    $state.video.pid = 0
    $state.video.watchdogPid = 0
    $state.video.startedAt = $null
    if ($state.mode -eq 'video') { $state.mode = 'idle' }
    Save-B65State -State $state
}

function Start-VideoInternal {
    $root = Get-B65ComfyRoot
    if (-not $root) {
        throw 'ComfyUI not found. Run scripts\Install-Video.ps1 first.'
    }
    $python = Get-B65ComfyPython
    if (-not $python) { throw "python_embeded not found under $root" }

    $state = Get-B65State
    if (Test-B65Pid -ProcessId ([int]$state.video.pid)) {
        Write-B65Log "ComfyUI already running (PID $($state.video.pid))" -Name 'comfy'
        return
    }

    if (Test-B65Pid -ProcessId ([int]$state.llm.pid)) {
        Write-B65Log 'LLM is running; stopping it to free VRAM/RAM.' -Name 'comfy'
        & (Join-Path $PSScriptRoot 'Llm.ps1') -Action stop
        Start-Sleep -Seconds 3
    }

    $comfyDir = Join-Path $root 'ComfyUI'
    $main = Join-Path $comfyDir 'main.py'
    if (-not (Test-Path -LiteralPath $main)) { throw "main.py not found: $main" }

    $yaml = Join-Path $comfyDir 'extra_model_paths.yaml'
    $startArgs = @(
        '-s', 'main.py',
        '--windows-standalone-build',
        '--listen', [string]$videoCfg.listen,
        '--port', [string]$videoCfg.port
    )
    if (Test-Path -LiteralPath $yaml) {
        $startArgs += @('--extra-model-paths-config', $yaml)
    }
    foreach ($extra in @($videoCfg.extraArgs)) {
        if ($null -ne $extra -and "$extra" -ne '') { $startArgs += [string]$extra }
    }

    $envMap = @{}
    foreach ($p in $videoCfg.env.PSObject.Properties) { $envMap[$p.Name] = [string]$p.Value }

    Write-B65Log ("Starting ComfyUI: {0} {1}" -f $python, ($startArgs -join ' ')) -Name 'comfy'
    $started = Start-B65Managed -Name 'comfy' -FilePath $python -ArgumentList $startArgs `
        -WorkingDirectory $comfyDir -Environment $envMap
    $proc = $started.Process

    $ok = Wait-B65Port -Port ([int]$videoCfg.port) -TimeoutSec ([int]$videoCfg.startTimeoutSec)
    if (-not $ok) {
        $tail = (Get-B65LogTail -Name 'comfy.stderr' -Lines 60) -join [Environment]::NewLine
        Stop-B65Managed -ProcessId $proc.Id -Name 'comfy' -WaitSec 5 | Out-Null
        throw "ComfyUI did not open port $($videoCfg.port). Last stderr:`n$tail"
    }

    $statsUri = 'http://127.0.0.1:{0}/system_stats' -f $videoCfg.port
    $healthy = Wait-B65Http -Uri $statsUri -TimeoutSec 120

    $state.video.pid = $proc.Id
    $state.video.port = [int]$videoCfg.port
    $state.video.startedAt = (Get-Date).ToString('o')
    $state.mode = 'video'
    Save-B65State -State $state

    if ($settings.watchdog.enabled) {
        $watch = Join-Path $PSScriptRoot 'Watch-Resources.ps1'
        $wd = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$watch`" -Target video" `
            -WindowStyle Hidden -PassThru
        $state = Get-B65State
        $state.video.watchdogPid = $wd.Id
        Save-B65State -State $state
    }

    Write-Host ''
    Write-Host 'ComfyUI is up.' -ForegroundColor Green
    Write-Host ("  UI     : http://127.0.0.1:{0}" -f $videoCfg.port)
    Write-Host ("  Health : {0}" -f $(if ($healthy) { 'ok' } else { 'port open, /system_stats not confirmed' }))
    Write-Host ''
}

switch ($Action) {
    'start'   { Start-VideoInternal }
    'stop'    { Stop-VideoInternal; Write-B65Log 'ComfyUI stopped.' -Name 'comfy' }
    'restart' { Stop-VideoInternal; Start-Sleep -Seconds 2; Start-VideoInternal }
    'status'  {
        $s = Get-B65Status
        $s.video | Format-List
        Write-Host ("RAM free: {0} GB / {1} GB   GPU dedicated: {2} MB" -f $s.memory.FreeGB, $s.memory.TotalGB, $s.gpu.DedicatedMB)
    }
}
