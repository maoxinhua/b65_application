# Llm.ps1 - start, stop, restart and inspect the local Qwen3.8-Flash-Next engine.
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status')][string]$Action = 'status',
    [switch]$OpenFirewall,
    [switch]$NoWatchdog
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$settings = Get-B65Config -Name settings
$llm = Get-B65Config -Name llm
$state = Get-B65State

function Get-LlmExe {
    $candidates = @($llm.exe, $llm.gui)
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $full = Resolve-B65Path -Path $c
        if (Test-Path -LiteralPath $full) { return $full }
    }
    return $null
}

function Stop-LlmInternal {
    $state = Get-B65State
    if ([int]$state.llm.pid -gt 0) {
        Stop-B65Managed -ProcessId ([int]$state.llm.pid) -Name 'llm' | Out-Null
    }
    if ([int]$state.llm.watchdogPid -gt 0) {
        Stop-B65Managed -ProcessId ([int]$state.llm.watchdogPid) -Name 'llm-watchdog' -WaitSec 5 | Out-Null
    }
    $state.llm.pid = 0
    $state.llm.watchdogPid = 0
    $state.llm.startedAt = $null
    if ($state.mode -eq 'llm') { $state.mode = 'idle' }
    Save-B65State -State $state
}

function Start-LlmInternal {
    $state = Get-B65State
    if (Test-B65Pid -ProcessId ([int]$state.llm.pid)) {
        Write-B65Log "LLM already running (PID $($state.llm.pid))" -Name 'llm'
        return
    }

    $exe = Get-LlmExe
    if (-not $exe) {
        throw 'XeStrata not found. Run scripts\Install-Llm.ps1 first.'
    }

    # Video and LLM share one GPU: stop video first.
    if (Test-B65Pid -ProcessId ([int]$state.video.pid)) {
        Write-B65Log 'Video engine is running; stopping it to free VRAM/RAM.' -Name 'llm'
        & (Join-Path $PSScriptRoot 'Video.ps1') -Action stop
        Start-Sleep -Seconds 3
    }

    if (-not $state.llm.apiKey) {
        $state.llm.apiKey = New-B65ApiKey
    }

    # Refuse to start an empty model directory: --yes would otherwise trigger a 68 GB download.
    if ($llm.modelsDir) {
        $modelsDir = Resolve-B65Path -Path ([string]$llm.modelsDir)
        $hasModel = $false
        if (Test-Path -LiteralPath $modelsDir) {
            $hasModel = [bool](Get-ChildItem -LiteralPath $modelsDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if (-not $hasModel) {
            throw "No model found in $modelsDir. Run: .\b65.ps1 install llm -RunSetup"
        }
    }

    $startArgs = @(
        '--model', [string]$llm.model,
        '--context', [string]$llm.context,
        '--host', [string]$llm.host,
        '--port', [string]$llm.port,
        '--api-key', [string]$state.llm.apiKey,
        '--no-browser',
        '--yes'
    )
    if (-not $llm.vision) { $startArgs += @('--vision', 'no') }
    if ($llm.source) { $startArgs += @('--source', [string]$llm.source) }
    if ($llm.dataDir) { $startArgs += @('--data-dir', (Resolve-B65Path -Path ([string]$llm.dataDir))) }
    if ($llm.modelsDir) { $startArgs += @('--models-dir', (Resolve-B65Path -Path ([string]$llm.modelsDir))) }
    if ([int]$llm.parallel -gt 1) { $startArgs += @('--parallel', [string]$llm.parallel) }
    if ($llm.optionalArgs) {
        $startArgs += @('--vram-reserve-mib', [string]$llm.vramReserveMiB)
    }
    foreach ($extra in @($llm.extraArgs)) {
        if ($null -ne $extra -and "$extra" -ne '') { $startArgs += [string]$extra }
    }

    Write-B65Log ("Starting LLM: {0} {1}" -f $exe, ($startArgs -join ' ')) -Name 'llm'
    $started = Start-B65Managed -Name 'llm' -FilePath $exe -ArgumentList $startArgs -WorkingDirectory (Split-Path -Parent $exe)
    $proc = $started.Process

    $ok = Wait-B65Port -Port ([int]$llm.port) -TimeoutSec ([int]$llm.startTimeoutSec)
    if (-not $ok) {
        $tail = (Get-B65LogTail -Name 'llm.stderr' -Lines 40) -join [Environment]::NewLine
        Stop-B65Managed -ProcessId $proc.Id -Name 'llm' -WaitSec 5 | Out-Null
        throw "LLM did not open port $($llm.port). Last stderr:`n$tail"
    }

    $headers = @{ Authorization = "Bearer $($state.llm.apiKey)" }
    $healthUri = 'http://127.0.0.1:{0}{1}' -f $llm.port, $llm.healthPath
    $healthy = Wait-B65Http -Uri $healthUri -TimeoutSec 60 -Headers $headers

    $state.llm.pid = $proc.Id
    $state.llm.port = [int]$llm.port
    $state.llm.model = [string]$llm.model
    $state.llm.context = [int]$llm.context
    $state.llm.startedAt = (Get-Date).ToString('o')
    $state.mode = 'llm'
    Save-B65State -State $state

    if ($OpenFirewall) {
        try {
            if (-not (Get-NetFirewallRule -DisplayName 'B65 LLM API' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'B65 LLM API' -Direction Inbound -Protocol TCP `
                    -LocalPort ([int]$llm.port) -Action Allow -Profile Private | Out-Null
            }
        } catch {
            Write-B65Log "Firewall rule failed: $($_.Exception.Message)" -Level WARN -Name 'llm'
        }
    }

    if (-not $NoWatchdog -and $settings.watchdog.enabled) {
        $watch = Join-Path $PSScriptRoot 'Watch-Resources.ps1'
        $wd = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$watch`" -Target llm" `
            -WindowStyle Hidden -PassThru
        $state = Get-B65State
        $state.llm.watchdogPid = $wd.Id
        Save-B65State -State $state
    }

    $lanIp = Get-B65LanIp
    Write-Host ''
    Write-Host 'LLM is up.' -ForegroundColor Green
    Write-Host ("  Local : http://127.0.0.1:{0}/v1" -f $llm.port)
    Write-Host ("  LAN   : http://{0}:{1}/v1" -f $lanIp, $llm.port)
    Write-Host ("  Key   : {0}" -f $state.llm.apiKey)
    Write-Host ("  Health: {0}" -f $(if ($healthy) { 'ok' } else { 'port open, /v1/models not confirmed' }))
    Write-Host ''
}

switch ($Action) {
    'start'   { Start-LlmInternal }
    'stop'    { Stop-LlmInternal; Write-B65Log 'LLM stopped.' -Name 'llm' }
    'restart' { Stop-LlmInternal; Start-Sleep -Seconds 2; Start-LlmInternal }
    'status'  {
        $s = Get-B65Status
        $s.llm | Format-List
        Write-Host ("RAM free: {0} GB / {1} GB   GPU dedicated: {2} MB" -f $s.memory.FreeGB, $s.memory.TotalGB, $s.gpu.DedicatedMB)
    }
}
