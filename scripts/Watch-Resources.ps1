# Watch-Resources.ps1 - sample RAM/VRAM and protect the desktop from the LLM.
# Started automatically by Llm.ps1 / Video.ps1; can also be run in a terminal.
[CmdletBinding()]
param(
    [ValidateSet('llm', 'video')][string]$Target = 'llm',
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$settings = Get-B65Config -Name settings
$wd = $settings.watchdog
$healthPath = Join-Path (Get-B65Path 'runtime') 'health.json'
$metricsPath = Join-Path (Join-Path (Get-B65Path 'runtime') 'logs') 'metrics.jsonl'
$lowCount = 0
$lastWarn = Get-Date
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-TargetPid {
    $s = Get-B65State
    if ($Target -eq 'llm') { return [int]$s.llm.pid }
    return [int]$s.video.pid
}

function Stop-TargetInternal {
    $s = Get-B65State
    if ($Target -eq 'llm') {
        Write-B65Log 'Watchdog: stopping LLM to protect system RAM.' -Level WARN -Name 'watchdog'
        Stop-B65Managed -ProcessId ([int]$s.llm.pid) -Name 'llm' | Out-Null
        $s.llm.pid = 0
        $s.llm.watchdogPid = 0
        $s.llm.startedAt = $null
        if ($s.mode -eq 'llm') { $s.mode = 'idle' }
    } else {
        Write-B65Log 'Watchdog: stopping ComfyUI to protect the GPU.' -Level WARN -Name 'watchdog'
        Stop-B65Managed -ProcessId ([int]$s.video.pid) -Name 'comfy' | Out-Null
        $s.video.pid = 0
        $s.video.watchdogPid = 0
        $s.video.startedAt = $null
        if ($s.mode -eq 'video') { $s.mode = 'idle' }
    }
    Save-B65State -State $s
}

while ($true) {
    $state = Get-B65State
    $targetPid = Get-TargetPid
    if (-not (Test-B65Pid -ProcessId $targetPid)) {
        Write-B65Log "Watchdog: $Target is not running, exit." -Name 'watchdog'
        break
    }

    $mem = Get-B65Memory
    $gpu = Get-B65Gpu
    $proc = Get-B65ProcessStats -ProcessId $targetPid
    $action = 'none'

    $grace = $true
    $started = $null
    if ($Target -eq 'llm') { $started = $state.llm.startedAt } else { $started = $state.video.startedAt }
    if ($started) {
        try {
            $age = ((Get-Date) - [datetime]$started).TotalSeconds
            $grace = ($age -lt [double]$wd.graceSeconds)
        } catch { $grace = $false }
    }

    if ($Target -eq 'llm') {
        if ($mem.FreeGB -lt [double]$wd.stopRamGB) {
            $lowCount++
            $action = 'low-ram'
            if (-not $grace -and $lowCount -ge [int]$wd.stopAfterSamples) {
                Stop-TargetInternal
                $action = 'stopped'
            }
        } else {
            $lowCount = 0
        }
        if (($mem.FreeGB -lt [double]$wd.warnRamGB) -and (((Get-Date) - $lastWarn).TotalSeconds -gt 60)) {
            Write-B65Log ("WARN: free RAM {0} GB (reserve target {1} GB)" -f $mem.FreeGB, $wd.reserveRamGB) -Level WARN -Name 'watchdog'
            $lastWarn = Get-Date
        }
        if (($mem.PageFilePct -gt [double]$wd.pageFileWarnPct) -and (((Get-Date) - $lastWarn).TotalSeconds -gt 60)) {
            Write-B65Log ("WARN: page file {0}% used" -f $mem.PageFilePct) -Level WARN -Name 'watchdog'
            $lastWarn = Get-Date
        }
    } else {
        if ($gpu.DedicatedMB -le 0) {
            $action = 'no-gpu-data'
        }
    }

    $health = [pscustomobject]@{
        updatedAt = (Get-Date).ToString('o')
        target    = $Target
        pid       = $targetPid
        memory    = $mem
        gpu       = $gpu
        process   = $proc
        action    = $action
        lowCount  = $lowCount
        thresholds = [pscustomobject]@{
            reserveRamGB = [double]$wd.reserveRamGB
            warnRamGB    = [double]$wd.warnRamGB
            stopRamGB    = [double]$wd.stopRamGB
        }
    }
    Write-B65Json -Path $healthPath -Value $health

    $metric = [pscustomobject]@{
        t = (Get-Date).ToString('o')
        target = $Target
        freeGB = $mem.FreeGB
        pagePct = $mem.PageFilePct
        vramMB = $gpu.DedicatedMB
        gpuPct = $gpu.UtilPct
        wsMB = $proc.WorkingSetMB
        procVramMB = $proc.VramMB
    }
    [System.IO.File]::AppendAllText($metricsPath, (($metric | ConvertTo-Json -Compress) + [Environment]::NewLine), $utf8)

    if ($Once) { break }
    Start-Sleep -Seconds ([int]$wd.sampleSeconds)
}
