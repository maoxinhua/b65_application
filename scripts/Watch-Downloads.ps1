# Watch-Downloads.ps1 - live view of model downloads (size, speed, ETA, processes).
[CmdletBinding()]
param(
    [int]$IntervalSec = 5,
    [switch]$Once,
    [switch]$NoClear,
    [int]$MaxRows = 12
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$manifest = Read-B65Json -Path (Join-Path (Get-B65Path 'config') 'models.json')
$expected = @{}
foreach ($f in $manifest.files) {
    $expected[(Resolve-B65Path -Path $f.target)] = [double]$f.sizeGB
}

$roots = @(
    (Get-B65Path 'models\comfyui'),
    (Get-B65Path 'models\llm')
)

function Get-DownloadFiles {
    $items = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $items += Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.part', '.safetensors', '.gguf') } |
            ForEach-Object { $_.Refresh(); $_ }
    }
    return @($items | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxRows)
}

function Get-LogTail {
    $log = Join-Path (Get-B65Path 'runtime\logs') 'download-video-console.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    $lines = Get-Content -LiteralPath $log -Tail 4 -ErrorAction SilentlyContinue
    return @($lines | ForEach-Object { ($_ -replace "`r", ' ').Trim() } | Where-Object { $_ } | Select-Object -Last 2)
}

$previous = @{}
while ($true) {
    $now = Get-Date
    $files = Get-DownloadFiles
    $rows = foreach ($f in $files) {
        $key = $f.FullName
        $sizeGB = $f.Length / 1GB
        $speed = 0.0
        if ($previous.ContainsKey($key)) {
            $dt = ($now - $previous[$key].Time).TotalSeconds
            if ($dt -gt 0) { $speed = (($f.Length - $previous[$key].Size) / 1MB) / $dt }
        }
        $previous[$key] = [pscustomobject]@{ Size = $f.Length; Time = $now }

        $eta = ''
        $base = $key -replace '\.part$', ''
        if ($expected.ContainsKey($base) -and $speed -gt 0.1) {
            $remain = $expected[$base] - $sizeGB
            if ($remain -gt 0) {
                $eta = [timespan]::FromSeconds(($remain * 1024) / $speed).ToString('hh\:mm')
            }
        }

        [pscustomobject]@{
            File    = $f.Name
            GB      = [math]::Round($sizeGB, 2)
            'MB/s'  = if ($speed -gt 0.05) { [math]::Round($speed, 2) } else { 0 }
            ETA     = $eta
            Updated = $f.LastWriteTime.ToString('HH:mm:ss')
        }
    }

    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('curl.exe', 'xestrata-cli.exe', 'python.exe') } |
        Select-Object Name, ProcessId)
    $driveLetter = (Split-Path -Qualifier (Get-B65Root)).TrimEnd(':')
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    $freeGB = if ($drive) { [math]::Round($drive.Free / 1GB, 1) } else { 0 }

    if (-not $NoClear) { Clear-Host }
    Write-Host ''
    Write-Host ('B65 downloads   {0}   free {1} GB on {2}:' -f $now.ToString('HH:mm:ss'), $freeGB, $driveLetter) -ForegroundColor Cyan
    if ($procs.Count -gt 0) {
        Write-Host ('Processes: ' + (($procs | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', '))
    } else {
        Write-Host 'Processes: no curl / xestrata / python running' -ForegroundColor Yellow
    }
    Write-Host ''
    if ($rows) {
        $rows | Format-Table -AutoSize
    } else {
        Write-Host 'No .part / .safetensors / .gguf files found.' -ForegroundColor Yellow
    }
    foreach ($line in (Get-LogTail)) {
        Write-Host ('log> ' + $line) -ForegroundColor DarkGray
    }
    Write-Host ''

    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
