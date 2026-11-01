# Llama27B.ps1 - Qwen3.8-27B quality engine via llama.cpp SYCL on the B65.
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'endpoint', 'use')][string]$Action = 'status',
    [int]$Context = 0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$configPath = Join-Path (Get-B65Path 'config') 'llm27b.json'
$cfg = Read-B65Json -Path $configPath

function Save-27BConfig {
    Write-B65Json -Path $configPath -Value $cfg
}

function Get-27BState {
    $st = Get-B65State
    if (-not $st.PSObject.Properties['llm27b']) {
        $st | Add-Member -NotePropertyName llm27b -NotePropertyValue ([pscustomobject]@{
            pid = 0; port = 0; apiKey = ''; model = ''; context = 0; startedAt = $null
        }) -Force
    }
    return $st
}

function Get-27BPort {
    if ($cfg.port) { return [int]$cfg.port }
    return 8096
}

function Get-27BHealth {
    $port = Get-27BPort
    try {
        $h = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/health' -f $port) -TimeoutSec 2
        if ($h -and $h.status -eq 'ok') { return $h }
    } catch { }
    return $null
}

function Get-27BProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'llama-server.exe' -and $_.CommandLine -match ('--port\s+' + (Get-27BPort)) })
}

function Stop-27BInternal {
    $st = Get-27BState
    $pids = @()
    if ([int]$st.llm27b.pid -gt 0) { $pids += [int]$st.llm27b.pid }
    $pids += @(Get-27BProcesses | ForEach-Object { [int]$_.ProcessId })
    foreach ($p in @($pids | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        Stop-B65Managed -ProcessId $p -Name 'llm27b' -WaitSec 20 | Out-Null
    }
    $st.llm27b.pid = 0
    $st.llm27b.port = 0
    $st.llm27b.startedAt = $null
    if ($st.mode -eq 'llm27b') { $st.mode = 'idle' }
    Save-B65State -State $st
}

function Start-27BInternal {
    $st = Get-27BState
    if ([int]$st.llm27b.pid -gt 0 -and (Test-B65Pid -ProcessId ([int]$st.llm27b.pid))) {
        $h = Get-27BHealth
        if ($h) { Write-Host "Qwen3.8-27B already running on port $(Get-27BPort)."; return }
    }

    $exe = Resolve-B65Path -Path ([string]$cfg.exe)
    $model = Resolve-B65Path -Path ([string]$cfg.model)
    $mtp = Resolve-B65Path -Path ([string]$cfg.mtp)
    if (-not (Test-Path -LiteralPath $exe)) { throw "llama-server not found: $exe" }
    if (-not (Test-Path -LiteralPath $model)) { throw "27B model not found: $model" }
    if (-not (Test-Path -LiteralPath $mtp)) { throw "27B MTP draft not found: $mtp" }

    # One GPU: stop the XeStrata engine and ComfyUI first.
    $cur = Get-B65State
    try { & (Join-Path $PSScriptRoot 'Llm.ps1') -Action stop | Out-Null } catch { }
    if ([int]$cur.video.pid -gt 0 -and (Test-B65Pid -ProcessId ([int]$cur.video.pid))) {
        try { & (Join-Path $PSScriptRoot 'Video.ps1') -Action stop | Out-Null } catch { }
    }

    if (-not $st.llm27b.apiKey) {
        $st.llm27b.apiKey = New-B65ApiKey
    }
    $port = Get-27BPort
    if ($Context -gt 0) { $cfg.context = $Context; Save-27BConfig }
    $ctx = [int]$cfg.context
    $threads = [int]$cfg.threads
    $args = @(
        '--model', $model,
        '--alias', [string]$cfg.modelName,
        '--host', [string]$cfg.host,
        '--port', [string]$port,
        '--api-key', [string]$st.llm27b.apiKey,
        '--ctx-size', [string]$ctx,
        '--n-gpu-layers', '999',
        '--device', [string]$cfg.device,
        '--split-mode', 'none',
        '--flash-attn', 'on',
        '--cache-type-k', [string]$cfg.cacheTypeK,
        '--cache-type-v', [string]$cfg.cacheTypeV,
        '--spec-type', 'draft-mtp',
        '--spec-draft-model', $mtp,
        '--spec-draft-ngl', '99',
        '--spec-draft-n-max', [string]$cfg.mtpDepth,
        '--spec-draft-p-min', '0.1',
        '--spec-draft-type-k', 'q8_0',
        '--spec-draft-type-v', 'q8_0',
        '--threads', [string]$threads,
        '--parallel', [string]$cfg.parallel,
        '--batch-size', [string]$cfg.batch,
        '--ubatch-size', [string]$cfg.ubatch,
        '--temp', [string]$cfg.temperature,
        '--top-p', [string]$cfg.topP,
        '--top-k', [string]$cfg.topK,
        '--presence-penalty', [string]$cfg.presencePenalty,
        '--jinja',
        '--metrics',
        '--fit', 'off'
    )

    $envs = @{
        'ONEAPI_DEVICE_SELECTOR' = [string]$cfg.gpuSelector
        'ZES_ENABLE_SYSMAN' = '1'
        'SYCL_CACHE_PERSISTENT' = '0'
        'GGML_SYCL_FA_ONEDNN' = '1'
    }
    Write-B65Log ("Starting Qwen3.8-27B: {0} {1}" -f $exe, ($args -join ' ')) -Name 'llm27b'
    $started = Start-B65Managed -Name 'llm27b' -FilePath $exe -ArgumentList $args -Environment $envs
    $proc = $started.Process
    $deadline = (Get-Date).AddSeconds([int]$cfg.startTimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $h = Get-27BHealth
        if ($h) { $ready = $true; break }
        if (-not (Test-B65Pid -ProcessId ([int]$proc.Id))) {
            $tail = (Get-B65LogTail -Name 'llm27b.stderr' -Lines 40) -join [Environment]::NewLine
            throw "Qwen3.8-27B exited before ready. Last stderr:`n$tail"
        }
    }
    if (-not $ready) { throw "Qwen3.8-27B did not become ready within $($cfg.startTimeoutSec)s." }

    $st.llm27b.pid = [int]$proc.Id
    $st.llm27b.port = [int]$port
    $st.llm27b.model = [string]$cfg.modelName
    $st.llm27b.context = [int]$ctx
    $st.llm27b.startedAt = (Get-Date).ToString('o')
    $st.mode = 'llm27b'
    Save-B65State -State $st

    Write-Host ''
    Write-Host "Qwen3.8-27B is up." -ForegroundColor Green
    Write-Host ("  Local : http://127.0.0.1:{0}/v1" -f $port)
    Write-Host ("  LAN   : http://{0}:{1}/v1" -f (Get-B65LanIp), $port)
    Write-Host ("  Model : {0}" -f $cfg.modelName)
    Write-Host ("  Quant : {0}   Context: {1}" -f $cfg.quant, $ctx)
    Write-Host ("  Key   : {0}" -f $st.llm27b.apiKey)
    Write-Host ''
}

function Show-27BStatus {
    $st = Get-27BState
    $h = Get-27BHealth
    $proc = if ([int]$st.llm27b.pid -gt 0) { Get-Process -Id ([int]$st.llm27b.pid) -ErrorAction SilentlyContinue } else { $null }
    $running = [bool]($h -and $proc)
    $out = [pscustomobject]@{
        running = $running
        pid = if ($proc) { [int]$proc.Id } else { 0 }
        port = if ($h) { Get-27BPort } else { 0 }
        model = [string]$cfg.modelName
        quant = [string]$cfg.quant
        context = [int]$cfg.context
        apiKey = if ($st.llm27b.apiKey) { [string]$st.llm27b.apiKey } else { '' }
        engine = 'llama.cpp SYCL'
    }
    if ($Json) { $out | ConvertTo-Json -Depth 4; return }
    Write-Host ''
    Write-Host '=== Qwen3.8-27B (quality) ==='
    Write-Host ('Status  : {0}' -f $(if ($running) { 'RUNNING' } else { 'stopped' }))
    Write-Host ('Model   : {0}  ({1})' -f $out.model, $out.quant)
    Write-Host ('Port    : {0}' -f $out.port)
    Write-Host ('Context : {0}' -f $out.context)
    Write-Host ''
}

function Show-27BEndpoint {
    $st = Get-27BState
    $lan = Get-B65LanIp
    $port = Get-27BPort
    [pscustomobject]@{
        baseURL = 'http://{0}:{1}/v1' -f $lan, $port
        localURL = 'http://127.0.0.1:{0}/v1' -f $port
        model = [string]$cfg.modelName
        apiKey = [string]$st.llm27b.apiKey
        context = [int]$cfg.context
        quant = [string]$cfg.quant
        engine = 'llama.cpp SYCL'
    } | ConvertTo-Json -Depth 4
}

switch ($Action) {
    'start' {
        if ($Context -gt 0) { $cfg.context = $Context; Save-27BConfig }
        Start-27BInternal
    }
    'stop' { Stop-27BInternal; Write-Host 'Qwen3.8-27B stopped.' }
    'restart' { Stop-27BInternal; Start-Sleep -Seconds 2; Start-27BInternal }
    'use' {
        if ($Context -gt 0) { $cfg.context = $Context; Save-27BConfig; Write-Host "Context set to $Context." }
        else { Write-Host "Context: $($cfg.context)" }
    }
    'status' { Show-27BStatus }
    'endpoint' { Show-27BEndpoint }
}
