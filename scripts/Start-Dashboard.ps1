# Start-Dashboard.ps1 - local web console (RAM/VRAM, start/stop, logs).
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$settings = Get-B65Config -Name settings
if ($Port -le 0) { $Port = [int]$settings.ports.dashboard }
if (Test-B65Port -Port $Port) { throw "Port $Port is already in use." }

$dashboardDir = (Get-B65Path 'dashboard')
$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

$state = Get-B65State
$state.dashboard.pid = $PID
$state.dashboard.port = $Port
Save-B65State -State $state

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.mp4'  = 'video/mp4'
    '.webm' = 'video/webm'
    '.ico'  = 'image/x-icon'
}

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$Status = 200)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Json {
    param($Context, $Value, [int]$Status = 200)
    $json = ConvertTo-Json -InputObject $Value -Depth 10
    if ($null -eq $json) { $json = 'null' }
    Send-Bytes -Context $Context -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -ContentType 'application/json; charset=utf-8' -Status $Status
}

function Start-Detached {
    param([string]$Arguments)
    $entry = Join-Path (Get-B65Root) 'b65.ps1'
    $cmd = "-NoProfile -ExecutionPolicy Bypass -File `"$entry`" $Arguments"
    $logDir = Join-Path (Get-B65Path 'runtime') 'logs'
    $outLog = Join-Path $logDir 'actions.stdout.log'
    $errLog = Join-Path $logDir 'actions.stderr.log'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog | Out-Null
}

Write-B65Log "Dashboard on $prefix" -Name 'dashboard'
if (-not $NoBrowser) { Start-Process $prefix | Out-Null }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $path = $ctx.Request.Url.AbsolutePath
            $method = $ctx.Request.HttpMethod

            if ($path -eq '/api/status' -and $method -eq 'GET') {
                Send-Json -Context $ctx -Value (Get-B65Status)
                continue
            }

            if ($path -eq '/api/health' -and $method -eq 'GET') {
                $hp = Join-Path (Get-B65Path 'runtime') 'health.json'
                if (Test-Path -LiteralPath $hp) { Send-Bytes -Context $ctx -Bytes ([IO.File]::ReadAllBytes($hp)) -ContentType 'application/json; charset=utf-8' }
                else { Send-Json -Context $ctx -Value @{ ok = $false; reason = 'no health sample yet' } }
                continue
            }

            if ($path -eq '/api/logs' -and $method -eq 'GET') {
                $name = $ctx.Request.QueryString['name']
                if (-not $name) { $name = 'control' }
                $lines = 120
                $q = $ctx.Request.QueryString['lines']
                if ($q) { $lines = [int]$q }
                Send-Json -Context $ctx -Value @(Get-B65LogTail -Name $name -Lines $lines)
                continue
            }

            if ($path -eq '/api/action' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $action = [string]$payload.action
                $map = @{
                    'llm-start'   = 'llm start'
                    'llm-stop'    = 'llm stop'
                    'video-start' = 'video start'
                    'video-stop'  = 'video stop'
                    'mode-llm'    = 'mode llm'
                    'mode-video'  = 'mode video'
                    'mode-idle'   = 'mode idle'
                }
                if (-not $map.ContainsKey($action)) {
                    Send-Json -Context $ctx -Value @{ ok = $false; error = "unknown action: $action" } -Status 400
                    continue
                }
                Write-B65Log "Dashboard action: $action" -Name 'dashboard'
                Start-Detached -Arguments $map[$action]
                Send-Json -Context $ctx -Value @{ ok = $true; action = $action } -Status 202
                continue
            }

            if ($path -eq '/api/render' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json
                $profile = [string]$payload.profile
                if (($profile -ne 'draft') -and ($profile -ne 'final')) {
                    Send-Json -Context $ctx -Value @{ ok = $false; error = 'profile must be draft or final' } -Status 400
                    continue
                }
                if (-not $payload.image -or -not $payload.prompt) {
                    Send-Json -Context $ctx -Value @{ ok = $false; error = 'image and prompt are required' } -Status 400
                    continue
                }
                $job = [pscustomobject]@{
                    profile = $profile
                    image = [string]$payload.image
                    prompt = [string]$payload.prompt
                    createdAt = (Get-Date).ToString('o')
                }
                $jobPath = Join-Path (Get-B65Path 'runtime') ('render-job-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
                Write-B65Json -Path $jobPath -Value $job
                Start-Detached -Arguments ("render -JobFile `"$jobPath`"")
                Send-Json -Context $ctx -Value @{ ok = $true; job = $jobPath } -Status 202
                continue
            }

            if ($path -eq '/api/outputs' -and $method -eq 'GET') {
                $folder = Join-Path (Get-B65Path 'output') 'shots'
                $list = @()
                if (Test-Path -LiteralPath $folder) {
                    $list = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -in @('.mp4', '.webm', '.png', '.jpg') } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 12 |
                        ForEach-Object {
                            [pscustomobject]@{
                                name = $_.Name
                                sizeMB = [math]::Round($_.Length / 1MB, 1)
                                time = $_.LastWriteTime.ToString('HH:mm:ss')
                                url = '/files/shots/' + [uri]::EscapeDataString($_.Name)
                            }
                        })
                }
                Send-Json -Context $ctx -Value $list
                continue
            }

            if ($path.StartsWith('/files/') -and $method -eq 'GET') {
                $rel = $path.Substring(7) -replace '/', '\'
                $outputRoot = [System.IO.Path]::GetFullPath((Get-B65Path 'output'))
                $full = [System.IO.Path]::GetFullPath((Join-Path $outputRoot $rel))
                if (-not $full.StartsWith($outputRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Send-Json -Context $ctx -Value @{ ok = $false; error = 'forbidden' } -Status 403
                    continue
                }
                if (-not (Test-Path -LiteralPath $full)) {
                    Send-Json -Context $ctx -Value @{ ok = $false; error = 'not found' } -Status 404
                    continue
                }
                $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
                $type = $mime[$ext]
                if (-not $type) { $type = 'application/octet-stream' }
                Send-Bytes -Context $ctx -Bytes ([IO.File]::ReadAllBytes($full)) -ContentType $type
                continue
            }

            if ($method -ne 'GET') {
                Send-Json -Context $ctx -Value @{ ok = $false; error = 'method not allowed' } -Status 405
                continue
            }

            if ($path -eq '/') { $path = '/index.html' }
            $relative = $path.TrimStart('/') -replace '/', '\'
            $full = [System.IO.Path]::GetFullPath((Join-Path $dashboardDir $relative))
            $rootFull = [System.IO.Path]::GetFullPath($dashboardDir)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-Json -Context $ctx -Value @{ ok = $false; error = 'forbidden' } -Status 403
                continue
            }
            if (-not (Test-Path -LiteralPath $full)) {
                Send-Json -Context $ctx -Value @{ ok = $false; error = 'not found' } -Status 404
                continue
            }
            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
            $type = $mime[$ext]
            if (-not $type) { $type = 'application/octet-stream' }
            Send-Bytes -Context $ctx -Bytes ([IO.File]::ReadAllBytes($full)) -ContentType $type
        } catch {
            try { Send-Json -Context $ctx -Value @{ ok = $false; error = $_.Exception.Message } -Status 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    $state = Get-B65State
    if ([int]$state.dashboard.pid -eq $PID) {
        $state.dashboard.pid = 0
        Save-B65State -State $state
    }
    Write-B65Log 'Dashboard stopped.' -Name 'dashboard'
}
