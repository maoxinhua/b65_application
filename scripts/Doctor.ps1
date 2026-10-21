# Doctor.ps1 - environment checks with actionable messages.
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row {
    param([string]$Item, [string]$Status, [string]$Detail)
    $rows.Add([pscustomobject]@{ Item = $Item; Status = $Status; Detail = $Detail })
}

Add-Row 'PowerShell' 'OK' $PSVersionTable.PSVersion.ToString()
Add-Row 'OS' 'OK' ([System.Environment]::OSVersion.VersionString)

$seven = Get-B65SevenZip
if ($seven) { Add-Row '7-Zip' 'OK' $seven } else { Add-Row '7-Zip' 'MISSING' 'run .\b65.ps1 setup' }

$ff = Get-B65Ffmpeg
if ($ff) { Add-Row 'FFmpeg' 'OK' $ff } else { Add-Row 'FFmpeg' 'MISSING' 'run .\b65.ps1 setup' }

$llmExe = Resolve-B65Path -Path (Get-B65Config -Name llm).exe
if (Test-Path -LiteralPath $llmExe) { Add-Row 'XeStrata' 'OK' $llmExe } else { Add-Row 'XeStrata' 'MISSING' 'run .\b65.ps1 install llm' }

$comfy = Get-B65ComfyRoot
if ($comfy) { Add-Row 'ComfyUI' 'OK' $comfy } else { Add-Row 'ComfyUI' 'MISSING' 'run .\b65.ps1 install video' }

$edge = Get-B65Edge
if ($edge) { Add-Row 'Edge (cards)' 'OK' $edge } else { Add-Row 'Edge (cards)' 'MISSING' 'install Microsoft Edge' }

$dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
if ($dotnet) {
    $runtimes = & $dotnet.Source --list-runtimes 2>$null
    if ($runtimes -match 'Microsoft\.WindowsDesktop\.App 10\.') { Add-Row '.NET 10 Desktop' 'OK' 'found' }
    else { Add-Row '.NET 10 Desktop' 'CHECK' 'download from dotnet.microsoft.com' }
} else {
    Add-Row '.NET 10 Desktop' 'MISSING' 'download from dotnet.microsoft.com'
}

$mem = Get-B65Memory
Add-Row 'RAM' 'OK' ("{0} GB total, {1} GB free" -f $mem.TotalGB, $mem.FreeGB)
$gpu = Get-B65Gpu
if ($gpu.Name) { Add-Row 'GPU' 'OK' ("{0}, {1} MB dedicated" -f $gpu.Name, $gpu.DedicatedMB) }
else { Add-Row 'GPU' 'WARN' 'GPU performance counters returned no name' }

$vcs = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
$activeDisplay = $vcs | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
if ($activeDisplay) {
    Add-Row 'Display' 'OK' ("{0} @ {1}x{2}" -f $activeDisplay.Name, $activeDisplay.CurrentHorizontalResolution, $activeDisplay.CurrentVerticalResolution)
}
$igpu = $vcs | Where-Object { $_.Name -match 'UHD Graphics' } | Select-Object -First 1
if ($igpu) { Add-Row 'iGPU' 'OK' $igpu.Name }

$ffQsv = Get-B65Ffmpeg
if ($ffQsv) {
    $qsvNames = @(& $ffQsv -hide_banner -encoders 2>$null | Select-String 'qsv' | ForEach-Object {
        ($_.ToString().Trim() -split '\s+')[1]
    })
    if ($qsvNames.Count -gt 0) { Add-Row 'QSV encoders' 'OK' ($qsvNames -join ', ') }
    else { Add-Row 'QSV encoders' 'MISSING' 'this FFmpeg build has no QSV' }
}

$settings = Get-B65Config -Name settings
foreach ($p in @('llm', 'comfy', 'dashboard')) {
    $port = [int]$settings.ports.$p
    $inUse = Test-B65Port -Port $port
    Add-Row "Port $p" $(if ($inUse) { 'IN USE' } else { 'FREE' }) "$port"
}

if ($Json) {
    $rows | ConvertTo-Json -Depth 5
    return
}
$rows | Format-Table -AutoSize
