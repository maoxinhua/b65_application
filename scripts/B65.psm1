# B65.psm1 - shared control-plane helpers for the B65 AI Workbench.
# ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

function Get-B65Root {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-B65Path {
    param([Parameter(Mandatory = $true)][string]$Name)
    return (Join-Path (Get-B65Root) $Name)
}

function Resolve-B65Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-B65Root) $Path)
}

function Read-B65Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing JSON file: $Path" }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Empty JSON file: $Path" }
    return ($raw | ConvertFrom-Json)
}

function Write-B65Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 12
    $tmp = "$Path.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-B65Config {
    param([string]$Name = 'settings')
    return (Read-B65Json -Path (Join-Path (Get-B65Path 'config') "$Name.json"))
}

function New-B65State {
    return [pscustomobject]@{
        version   = 1
        mode      = 'idle'
        updatedAt = (Get-Date).ToString('o')
        llm       = [pscustomobject]@{ pid = 0; port = 8095; apiKey = ''; startedAt = $null; model = ''; context = 0; watchdogPid = 0 }
        video     = [pscustomobject]@{ pid = 0; port = 8188; startedAt = $null; watchdogPid = 0 }
        dashboard = [pscustomobject]@{ pid = 0; port = 8099 }
    }
}

function Get-B65State {
    $path = Join-Path (Get-B65Path 'runtime') 'state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        $state = New-B65State
        Save-B65State -State $state
        return $state
    }
    return (Read-B65Json -Path $path)
}

function Save-B65State {
    param([Parameter(Mandatory = $true)]$State)
    $State.updatedAt = (Get-Date).ToString('o')
    Write-B65Json -Path (Join-Path (Get-B65Path 'runtime') 'state.json') -Value $State
}

function Write-B65Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$Name = 'control'
    )
    $dir = Join-Path (Get-B65Path 'runtime') 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $file = Join-Path $dir "$Name.log"
    $line = '[{0}][{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine, $utf8)
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
}

function Get-B65LogTail {
    param([string]$Name = 'control', [int]$Lines = 120)
    $file = Join-Path (Join-Path (Get-B65Path 'runtime') 'logs') "$Name.log"
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @([System.IO.File]::ReadLines($file) | Select-Object -Last $Lines)
}

function New-B65ApiKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hex = [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    return $hex.Substring(0, 40)
}

function Get-B65LanIp {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
            $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Hyper-V|VirtualBox|VMware|Tailscale'
        } |
        Sort-Object -Property InterfaceIndex
    $first = $ips | Select-Object -First 1
    if ($first) { return $first.IPAddress }
    return '127.0.0.1'
}

function Test-B65Port {
    param([Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 600)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($ar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-B65Port {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSec = 120,
        [int]$IntervalSec = 1
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-B65Port -Port $Port) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function Wait-B65Http {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 120,
        [hashtable]$Headers = @{}
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -TimeoutSec 5
            return $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Enter-B65Lock {
    param([int]$TimeoutMs = 60000)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\B65WorkbenchControl')
    if (-not $mutex.WaitOne($TimeoutMs)) {
        $mutex.Dispose()
        throw 'Another B65 operation is running (lock timeout).'
    }
    return $mutex
}

function Exit-B65Lock {
    param([Parameter(Mandatory = $true)]$Mutex)
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

function Test-B65Pid {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return (-not $p.HasExited)
    } catch {
        return $false
    }
}

function ConvertTo-B65Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Start-B65Managed {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-B65Root),
        [hashtable]$Environment = @{},
        [string]$StdOut = $null,
        [string]$StdErr = $null
    )
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Executable not found: $FilePath" }
    $logDir = Join-Path (Get-B65Path 'runtime') 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    if (-not $StdOut) { $StdOut = Join-Path $logDir "$Name.stdout.log" }
    if (-not $StdErr) { $StdErr = Join-Path $logDir "$Name.stderr.log" }

    $old = @{}
    foreach ($key in $Environment.Keys) {
        $old[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }
    try {
        $argString = (($ArgumentList | ForEach-Object { ConvertTo-B65Arg $_ }) -join ' ')
        $proc = Start-Process -FilePath $FilePath `
            -ArgumentList $argString `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $StdOut `
            -RedirectStandardError $StdErr `
            -WindowStyle Hidden `
            -PassThru
        Start-Sleep -Milliseconds 400
        return [pscustomobject]@{ Process = $proc; StdOut = $StdOut; StdErr = $StdErr; Args = $argString }
    } finally {
        foreach ($key in $old.Keys) {
            [Environment]::SetEnvironmentVariable($key, $old[$key], 'Process')
        }
    }
}

function Stop-B65Managed {
    param([int]$ProcessId, [string]$Name = 'process', [int]$WaitSec = 20)
    if (-not (Test-B65Pid -ProcessId $ProcessId)) { return $true }
    Write-B65Log "Stopping $Name (PID $ProcessId)..." -Name 'control'
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-B65Pid -ProcessId $ProcessId)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 1
    return (-not (Test-B65Pid -ProcessId $ProcessId))
}

function Get-B65Memory {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedGB = [math]::Round($totalGB - $freeGB, 1)
    $usedPct = 0
    if ($totalGB -gt 0) { $usedPct = [math]::Round(100 * $usedGB / $totalGB, 1) }

    $pfTotalMB = 0
    $pfUsedMB = 0
    $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pf) {
        $pfTotalMB = ($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum
        $pfUsedMB = ($pf | Measure-Object -Property CurrentUsage -Sum).Sum
    }
    $pfPct = 0
    if ($pfTotalMB -gt 0) { $pfPct = [math]::Round(100 * $pfUsedMB / $pfTotalMB, 1) }

    return [pscustomobject]@{
        TotalGB   = $totalGB
        FreeGB    = $freeGB
        UsedGB    = $usedGB
        UsedPct   = $usedPct
        PageFileTotalMB = [math]::Round($pfTotalMB, 0)
        PageFileUsedMB  = [math]::Round($pfUsedMB, 0)
        PageFilePct     = $pfPct
    }
}

function Get-B65Gpu {
    $name = ''
    $dedicatedMB = 0
    $sharedMB = 0
    $utilPct = 0

    $mem = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction SilentlyContinue
    if ($mem) {
        $rows = @($mem)
        $dedicatedMB = [math]::Round((($rows | Measure-Object -Property DedicatedUsage -Sum).Sum) / 1MB, 0)
        $sharedMB = [math]::Round((($rows | Measure-Object -Property SharedUsage -Sum).Sum) / 1MB, 0)
        $named = $rows | Where-Object { $_.DedicatedUsage -gt 0 } | Select-Object -First 1
        if ($named) { $name = $named.Name }
    }
    $vc = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Arc' } | Select-Object -First 1
    if (-not $vc) {
        $vc = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1
    }
    if ($vc) { $name = $vc.Name }

    $eng = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue
    if ($eng) {
        $u = ($eng | Where-Object { $_.Name -match 'engtype_3D' } | Measure-Object -Property UtilizationPercentage -Sum).Sum
        if ($u) { $utilPct = [math]::Min(100, [math]::Round($u, 0)) }
    }

    return [pscustomobject]@{
        Name        = $name
        DedicatedMB = $dedicatedMB
        SharedMB    = $sharedMB
        UtilPct     = $utilPct
    }
}

function Get-B65ProcessVramMB {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return 0 }
    $pm = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction SilentlyContinue
    if (-not $pm) { return 0 }
    $rows = $pm | Where-Object { $_.Name -match "pid_$ProcessId_" }
    if (-not $rows) { return 0 }
    return [math]::Round((($rows | Measure-Object -Property DedicatedUsage -Sum).Sum) / 1MB, 0)
}

function Get-B65ProcessStats {
    param([int]$ProcessId)
    if (-not (Test-B65Pid -ProcessId $ProcessId)) {
        return [pscustomobject]@{ Alive = $false; Pid = $ProcessId; WorkingSetMB = 0; PrivateMB = 0; CpuSec = 0; VramMB = 0 }
    }
    $p = Get-Process -Id $ProcessId
    return [pscustomobject]@{
        Alive       = $true
        Pid         = $ProcessId
        WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
        PrivateMB   = [math]::Round($p.PrivateMemorySize64 / 1MB, 0)
        CpuSec      = [math]::Round($p.CPU, 1)
        VramMB      = (Get-B65ProcessVramMB -ProcessId $ProcessId)
    }
}

function Get-B65LlmSetup {
    $p = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'xestrata-cli.exe' -and $_.CommandLine -match '--setup' } |
        Select-Object -First 1
    if (-not $p) { return $null }
    $model = ''
    if ($p.CommandLine -match '--model\s+("[^"]+"|\S+)') { $model = $Matches[1].Trim('"') }
    return [pscustomobject]@{ running = $true; pid = [int]$p.ProcessId; model = $model }
}

function Get-B65LlmLive {
    # XeStrata's setup.py may hand server.py a different port than --port.
    # Detect the live engine from process command lines + /health instead of trusting state.json.
    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('xestrata-cli.exe', 'python.exe', 'strata.exe') })
    $cli = $procs | Where-Object { $_.Name -eq 'xestrata-cli.exe' -and $_.CommandLine -match '--model' } | Select-Object -First 1
    $srv = $procs | Where-Object { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'serve[\\/]server\.py' } | Select-Object -First 1
    $strata = $procs | Where-Object { $_.Name -eq 'strata.exe' } | Select-Object -First 1
    if (-not $cli -and -not $srv) { return $null }

    $apiKey = ''
    $ctx = 0
    $model = ''
    $port = 0
    $configPath = ''
    if ($cli) {
        if ($cli.CommandLine -match '--api-key\s+("[^"]+"|\S+)') { $apiKey = $Matches[1].Trim('"') }
        if ($cli.CommandLine -match '--context\s+(\d+)') { $ctx = [int]$Matches[1] }
        if ($cli.CommandLine -match '--model\s+("[^"]+"|\S+)') { $model = $Matches[1].Trim('"') }
        if ($cli.CommandLine -match '--port\s+(\d+)') { $port = [int]$Matches[1] }
    }
    if ($srv) {
        if ($srv.CommandLine -match '--port\s+(\d+)') { $port = [int]$Matches[1] }
        if ($srv.CommandLine -match '--config\s+("[^"]+"|\S+)') { $configPath = $Matches[1].Trim('"') }
    }
    if ($configPath -and (Test-Path -LiteralPath $configPath)) {
        try {
            $cfg = Read-B65Json -Path $configPath
            if (-not $apiKey -and $cfg.api_key) { $apiKey = [string]$cfg.api_key }
            if (-not $model -and $cfg.model_name) { $model = [string]$cfg.model_name }
            if ($port -le 0 -and $cfg.port) { $port = [int]$cfg.port }
        } catch { }
    }

    $candidates = @($port)
    if ($cli -and $cli.CommandLine -match '--port\s+(\d+)') { $candidates += [int]$Matches[1] }
    try { $candidates += [int](Get-B65State).llm.port } catch { }
    $candidates += 8095
    $candidates = @($candidates | Where-Object { $_ -gt 0 } | Select-Object -Unique)

    $health = $null
    $livePort = 0
    foreach ($p in $candidates) {
        try {
            $h = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/health' -f $p) -TimeoutSec 2
            if ($h -and $h.status -eq 'ok') { $health = $h; $livePort = $p; break }
        } catch { }
    }
    # A --setup/download process has no server.py and no /health; it is not a serving engine.
    if (-not $health -and -not $srv) { return $null }
    if ($livePort -gt 0) { $port = $livePort }
    if ($health) {
        if ($health.model) { $model = [string]$health.model }
        if ($health.max_context) { $ctx = [int]$health.max_context }
    }

    return [pscustomobject]@{
        running       = $true
        ready         = [bool]$health
        pid           = if ($srv) { [int]$srv.ProcessId } elseif ($cli) { [int]$cli.ProcessId } else { 0 }
        cliPid        = if ($cli) { [int]$cli.ProcessId } else { 0 }
        serverPid     = if ($srv) { [int]$srv.ProcessId } else { 0 }
        strataPid     = if ($strata) { [int]$strata.ProcessId } else { 0 }
        port          = [int]$port
        model         = $model
        context       = [int]$ctx
        apiKey        = $apiKey
        apiKeyRequired = if ($health) { [bool]$health.api_key } else { $false }
        configPath    = $configPath
        health        = $health
    }
}

function Get-B65Status {
    $settings = Get-B65Config -Name settings
    $llmCfg = Get-B65Config -Name llm
    $state = Get-B65State
    $mem = Get-B65Memory
    $gpu = Get-B65Gpu

    $live = Get-B65LlmLive
    $setup = Get-B65LlmSetup
    $llmAlive = [bool]$live
    $videoAlive = Test-B65Pid -ProcessId ([int]$state.video.pid)
    $llmPid = if ($live) { [int]$live.pid } else { [int]$state.llm.pid }
    $llmPort = if ($live -and $live.port -gt 0) { [int]$live.port } else { [int]$state.llm.port }
    $llmModel = if ($live -and $live.model) { [string]$live.model } elseif ($llmAlive) { [string]$state.llm.model } else { [string]$llmCfg.model }
    $llmCtx = if ($live -and $live.context -gt 0) { [int]$live.context } elseif ($llmAlive) { [int]$state.llm.context } else { [int]$llmCfg.context }
    $llmKey = if ($live -and $live.apiKey) { [string]$live.apiKey } else { $state.llm.apiKey }
    $llmVramPid = if ($live -and $live.strataPid -gt 0) { [int]$live.strataPid } elseif ($llmPid -gt 0) { $llmPid } else { 0 }
    $mode = if ($live) { 'llm' } else { $state.mode }

    $health = $null
    $healthPath = Join-Path (Get-B65Path 'runtime') 'health.json'
    if (Test-Path -LiteralPath $healthPath) {
        try {
            $health = Read-B65Json -Path $healthPath
            $age = ((Get-Date) - [datetime]$health.updatedAt).TotalSeconds
            if ($age -gt 30) { $health = $null }
        } catch { $health = $null }
    }

    return [pscustomobject]@{
        updatedAt = (Get-Date).ToString('o')
        mode      = $mode
        lanIp     = (Get-B65LanIp)
        memory    = $mem
        gpu       = $gpu
        llm       = [pscustomobject]@{
            running   = $llmAlive
            ready     = if ($live) { [bool]$live.ready } else { $false }
            pid       = $llmPid
            port      = $llmPort
            model     = $llmModel
            context   = $llmCtx
            startedAt = $state.llm.startedAt
            apiKey    = $llmKey
            apiKeyRequired = if ($live) { [bool]$live.apiKeyRequired } else { $false }
            setup     = $setup
            stats     = (Get-B65ProcessStats -ProcessId $llmPid)
            vramMB    = (Get-B65ProcessVramMB -ProcessId $llmVramPid)
        }
        video     = [pscustomobject]@{
            running   = $videoAlive
            pid       = [int]$state.video.pid
            port      = [int]$state.video.port
            startedAt = $state.video.startedAt
            stats     = (Get-B65ProcessStats -ProcessId ([int]$state.video.pid))
            vramMB    = (Get-B65ProcessVramMB -ProcessId ([int]$state.video.pid))
        }
        watchdog  = $health
        ports     = [pscustomobject]@{
            llm       = (Test-B65Port -Port $llmPort)
            comfy     = (Test-B65Port -Port ([int]$settings.ports.comfy))
            dashboard = (Test-B65Port -Port ([int]$settings.ports.dashboard))
        }
    }
}

function Get-B65ComfyRoot {
    $videoCfg = Get-B65Config -Name video
    $configured = Resolve-B65Path -Path $videoCfg.root
    if ((Test-Path -LiteralPath (Join-Path $configured 'python_embeded\python.exe')) -or
        (Test-Path -LiteralPath (Join-Path $configured 'python_embedded\python.exe')) -or
        (Test-Path -LiteralPath (Join-Path $configured 'python_standalone\python.exe'))) { return $configured }

    $apps = Get-B65Path 'apps'
    if (Test-Path -LiteralPath $apps) {
        $candidates = @(Get-ChildItem -LiteralPath $apps -Directory -Filter 'ComfyUI*' -ErrorAction SilentlyContinue | Sort-Object Name)
        $preferred = Join-Path $apps 'ComfyUI_windows_portable'
        if (Test-Path -LiteralPath $preferred) { $candidates = @($preferred) + @($candidates | Where-Object Name -ne 'ComfyUI_windows_portable') }
        foreach ($dir in $candidates) {
            $dir = Get-Item -LiteralPath $dir
            foreach ($py in @('python_embeded\python.exe', 'python_embedded\python.exe', 'python_standalone\python.exe')) {
                if (Test-Path -LiteralPath (Join-Path $dir.FullName $py)) { return $dir.FullName }
            }
        }
    }
    return $null
}

function Get-B65ComfyPython {
    $root = Get-B65ComfyRoot
    if (-not $root) { return $null }
    foreach ($py in @('python_embeded\python.exe', 'python_embedded\python.exe', 'python_standalone\python.exe')) {
        $candidate = Join-Path $root $py
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Invoke-B65Comfy {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Method = 'Get',
        $Body = $null,
        [int]$TimeoutSec = 60
    )
    $videoCfg = Get-B65Config -Name video
    $uri = 'http://127.0.0.1:{0}{1}' -f $videoCfg.port, $Path
    $params = @{ Uri = $uri; Method = $Method; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 100 -Compress)
        $params.ContentType = 'application/json'
    }
    return (Invoke-RestMethod @params)
}

function Set-B65WorkflowValue {
    param(
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$InputName,
        $Value
    )
    $nodeProp = $Workflow.PSObject.Properties[$NodeId]
    if (-not $nodeProp) { throw "Workflow node '$NodeId' not found." }
    $node = $nodeProp.Value
    if (-not $node.inputs) { $node | Add-Member -NotePropertyName inputs -NotePropertyValue ([pscustomobject]@{}) }
    $inputProp = $node.inputs.PSObject.Properties[$InputName]
    if ($inputProp) {
        $node.inputs.$InputName = $Value
    } else {
        $node.inputs | Add-Member -NotePropertyName $InputName -NotePropertyValue $Value -Force
    }
}

function Test-B65Workflow {
    param([Parameter(Mandatory = $true)]$Workflow)

    # ComfyUI's object_info contains duplicate keys that differ only by case;
    # PowerShell 5.1's ConvertFrom-Json refuses it. Validate in ComfyUI's Python.
    $python = Get-B65ComfyPython
    $helper = Join-Path (Get-B65Path 'scripts') 'comfy_validate.py'
    if ($python -and (Test-Path -LiteralPath $helper)) {
        $tmp = Join-Path (Get-B65Path 'runtime') 'workflow-validate.json'
        Write-B65Json -Path $tmp -Value $Workflow
        $videoCfg = Get-B65Config -Name video
        $base = 'http://127.0.0.1:{0}' -f $videoCfg.port
        $raw = & $python -s $helper $tmp $base 2>&1
        $text = (($raw | Out-String).Trim())
        try {
            $obj = $text | ConvertFrom-Json
        } catch {
            throw "Workflow validation helper failed: $text"
        }
        return [pscustomobject]@{ Ok = [bool]$obj.ok; Issues = @($obj.issues) }
    }

    # Fallback (may fail on ComfyUI versions with case-duplicate object_info keys).
    $info = Invoke-B65Comfy -Path '/object_info' -TimeoutSec 180
    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $Workflow.PSObject.Properties) {
        if ($prop.Name -eq '_meta') { continue }
        $node = $prop.Value
        $class = [string]$node.class_type
        $classInfo = $info.PSObject.Properties[$class]
        if (-not $classInfo) {
            $issues.Add("Node $($prop.Name): unknown class_type '$class'")
            continue
        }
        $required = @()
        $optional = @()
        if ($classInfo.Value.input.required) { $required = @($classInfo.Value.input.required.PSObject.Properties.Name) }
        if ($classInfo.Value.input.optional) { $optional = @($classInfo.Value.input.optional.PSObject.Properties.Name) }
        foreach ($ip in $node.inputs.PSObject.Properties) {
            if ($ip.Name -eq '_meta') { continue }
            if ($ip.Value -is [array]) { continue }
            if (($required -notcontains $ip.Name) -and ($optional -notcontains $ip.Name)) {
                $issues.Add("Node $($prop.Name) ($class): unknown input '$($ip.Name)'")
            }
        }
    }
    return [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues }
}

function Get-B65Ffmpeg {
    $local = Join-Path (Get-B65Path 'tools') 'ffmpeg\bin\ffmpeg.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-B65Edge {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-B65SevenZip {
    foreach ($rel in @('tools\7zip\7zr.exe', 'tools\7zr.exe', 'tools\7zip\7z.exe')) {
        $full = Join-Path (Get-B65Root) $rel
        if (Test-Path -LiteralPath $full) { return $full }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-B65Download {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$Force,
        [long]$MinBytes = 0
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $OutFile) {
        $len = (Get-Item -LiteralPath $OutFile).Length
        if ((-not $Force) -and ($len -ge $MinBytes)) {
            Write-B65Log "Exists, skip download: $OutFile" -Name 'setup'
            return
        }
        if (-not $Force) {
            Write-B65Log ("Incomplete download ({0} bytes, expected at least {1}); fetching it again: {2}" -f $len, $MinBytes, $OutFile) -Level WARN -Name 'setup'
        }
        Remove-Item -LiteralPath $OutFile -Force
    }
    $tmp = "$OutFile.part"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    # curl -C - appends to existing output; a completed file that failed only archive validation must start over.
    if ($Force -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force }
    if (Test-Path -LiteralPath $tmp) {
        $tmpLen = (Get-Item -LiteralPath $tmp).Length
        if (-not $curl) { Remove-Item -LiteralPath $tmp -Force }
        elseif ($tmpLen -gt 0) { Write-B65Log ("Resuming download from {0} bytes" -f $tmpLen) -Name 'setup' }
    }
    Write-B65Log "Downloading $Uri" -Name 'setup'
    if ($curl) {
        & $curl.Source -L --fail --retry 5 --retry-all-errors --retry-delay 10 -C - -o $tmp $Uri
        if ($LASTEXITCODE -ne 0) { throw "curl failed ($LASTEXITCODE) for $Uri (partial kept at $tmp)" }
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing
    }
    if (-not (Test-Path -LiteralPath $tmp)) { throw "Download did not produce $tmp" }
    $size = (Get-Item -LiteralPath $tmp).Length
    if (($MinBytes -gt 0) -and ($size -lt $MinBytes)) {
        throw ("Downloaded file is too small: {0} bytes (expected at least {1}); partial kept at {2}" -f $size, $MinBytes, $tmp)
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Test-B65Archive {
    param([Parameter(Mandatory = $true)][string]$Archive)
    if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }

    # 7zr.exe is a reduced 7-Zip build: it opens 7z, not zip. Validate zip with .NET.
    if ($Archive -like '*.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
            $zip.Dispose()
            return $true
        } catch {
            throw "Archive is incomplete or corrupt: $Archive ($($_.Exception.Message))"
        }
    }

    # Split 7z sets: .001 is the archive, .002.. are continuation volumes.
    # Opening a continuation volume on its own always fails, so normalize to .001.
    if ($Archive -match '\.7z\.\d{3}$') {
        $firstVolume = $Archive -replace '\.7z\.\d{3}$', '.7z.001'
        if (Test-Path -LiteralPath $firstVolume) { $Archive = $firstVolume }
    }

    $seven = Get-B65SevenZip
    if (-not $seven) { throw '7-Zip not found. Run .\b65.ps1 setup first.' }
    & $seven t $Archive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Archive is incomplete or corrupt: $Archive (remove it and run the install again)" }
    return $true
}

function Expand-B65Zip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Archive)) { throw "Archive not found: $Archive" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-B65Log "Extracting $Archive" -Name 'setup'
    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force -ErrorAction Stop
    } catch {
        Write-B65Log ("Expand-Archive failed ({0}); retrying with 7-Zip" -f $_.Exception.Message) -Level WARN -Name 'setup'
        Expand-B65SevenZip -Archive $Archive -Destination $Destination
    }
}

function Expand-B65SevenZip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $seven = Get-B65SevenZip
    if (-not $seven) { throw '7-Zip not found. Run scripts\Setup.ps1 first.' }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-B65Log "Extracting $Archive" -Name 'setup'
    & $seven x $Archive "-o$Destination" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed ($LASTEXITCODE) for $Archive; incomplete files are at $Destination" }
}

Export-ModuleMember -Function *
