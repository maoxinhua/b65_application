# Get-GpuTemp.ps1 - read Arc GPU temperature, power and memory via Intel xpu-smi.
# Sysman is admin-only on Windows, so the script self-elevates once (UAC prompt).
[CmdletBinding()]
param(
    [int]$Device = 0,
    [switch]$Elevated,
    [switch]$NoElevate,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$xpu = Get-ChildItem -LiteralPath (Join-Path (Get-B65Path 'tools') 'xpu-smi') -Recurse -Filter 'xpu-smi.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $xpu) {
    throw 'xpu-smi not found. Run: .\b65.ps1 setup'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ((-not $isAdmin) -and (-not $Elevated)) {
    if ($NoElevate) {
        throw 'xpu-smi needs an elevated PowerShell (Sysman is admin-only on Windows).'
    }
    $temp = Join-Path $env:TEMP ('b65-gputemp-' + [guid]::NewGuid().ToString('N') + '.txt')
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Device {1} -Elevated -OutFile "{2}"' -f $PSCommandPath, $Device, $temp
    Write-Host 'Requesting administrator privileges (UAC) ...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -Wait | Out-Null
    if (Test-Path -LiteralPath $temp) {
        Get-Content -LiteralPath $temp -Raw
        Remove-Item -LiteralPath $temp -Force
    } else {
        Write-Host 'No output was produced (UAC declined?).' -ForegroundColor Yellow
    }
    return
}

if (-not $isAdmin) {
    throw 'Still not elevated. Open PowerShell as Administrator and run this script again.'
}

$query = 'temperature.gpu,power.draw,memory.used,utilization.gpu'
$out = & $xpu.FullName --query-gpu=$query --id $Device 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String).Trim()

if (($code -ne 0) -or ($text -match 'failed|error')) {
    $out = & $xpu.FullName stats -d $Device 2>&1
    $text = ($out | Out-String).Trim()
}

if (-not $text) { $text = 'xpu-smi returned no data.' }
if ($OutFile) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $text, $utf8)
}
Write-Host $text
