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
    $live = Get-B65LlmLive
    $pids = @()
    if ($live) {
        $pids += [int]$live.cliPid
        $pids += [int]$live.serverPid
        $pids += [int]$live.strataPid
    }
    $pids += [int]$state.llm.pid
    foreach ($pidToStop in @($pids | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        Stop-B65Managed -ProcessId $pidToStop -Name 'llm' -WaitSec 15 | Out-Null
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
    $live = Get-B65LlmLive
    if ($live -and $live.running) {
        $state.llm.pid = [int]$live.pid
        $state.llm.port = [int]$live.port
        $state.llm.apiKey = [string]$live.apiKey
        $state.llm.model = [string]$live.model
        $state.llm.context = [int]$live.context
        $state.llm.startedAt = $state.llm.startedAt
        $state.mode = 'llm'
        Save-B65State -State $state
        Write-B65Log ("LLM already running (PID {0}, port {1}, model {2})." -f $live.pid, $live.port, $live.model) -Name 'llm'
        return
    }
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

    # XeStrata may bind a different port than --port (setup.py hands server.py its own choice).
    $deadline = (Get-Date).AddSeconds([int]$llm.startTimeoutSec)
    $live = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $live = Get-B65LlmLive
        if ($live -and $live.ready) { break }
        if (-not (Test-B65Pid -ProcessId $proc.Id) -and -not ($live -and $live.running)) {
            $tail = (Get-B65LogTail -Name 'llm.stderr' -Lines 40) -join [Environment]::NewLine
            throw "LLM process exited before opening a port. Last stderr:`n$tail"
        }
    }
    if (-not $live -or -not $live.ready) {
        $tail = (Get-B65LogTail -Name 'llm.stderr' -Lines 40) -join [Environment]::NewLine
        Stop-B65Managed -ProcessId $proc.Id -Name 'llm' -WaitSec 5 | Out-Null
        throw "LLM did not become healthy within $($llm.startTimeoutSec)s. Last stderr:`n$tail"
    }

    $actualPort = [int]$live.port
    $actualKey = if ($live.apiKey) { [string]$live.apiKey } else { [string]$state.llm.apiKey }
    $actualModel = if ($live.model) { [string]$live.model } else { [string]$llm.model }
    $actualContext = if ($live.context -gt 0) { [int]$live.context } else { [int]$llm.context }

    $headers = @{ Authorization = "Bearer $actualKey" }
    $healthUri = 'http://127.0.0.1:{0}{1}' -f $actualPort, $llm.healthPath
    $healthy = Wait-B65Http -Uri $healthUri -TimeoutSec 60 -Headers $headers

    $state.llm.pid = $proc.Id
    $state.llm.port = $actualPort
    $state.llm.apiKey = $actualKey
    $state.llm.model = $actualModel
    $state.llm.context = $actualContext
    $state.llm.startedAt = (Get-Date).ToString('o')
    $state.mode = 'llm'
    Save-B65State -State $state

    if ($OpenFirewall) {
        try {
            if (-not (Get-NetFirewallRule -DisplayName 'B65 LLM API' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'B65 LLM API' -Direction Inbound -Protocol TCP `
                    -LocalPort $actualPort -Action Allow -Profile Private | Out-Null
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
    Write-Host ("  Local : http://127.0.0.1:{0}/v1" -f $actualPort)
    Write-Host ("  LAN   : http://{0}:{1}/v1" -f $lanIp, $actualPort)
    Write-Host ("  Model : {0}" -f $actualModel)
    Write-Host ("  Key   : {0}" -f $actualKey)
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
