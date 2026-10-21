# Test-Qsv.ps1 - find the two Intel adapters and benchmark H.264 encode paths.
# Useful before deciding whether the iGPU is worth using for media work.
[CmdletBinding()]
param(
    [int]$Seconds = 5,
    [string[]]$Resolutions = @('1920x1080', '3840x2160'),
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$ff = Get-B65Ffmpeg
if (-not $ff) { throw 'FFmpeg not found. Run .\b65.ps1 setup.' }

function Get-QsvAdapterName {
    param([int]$Device)
    $out = & $ff -hide_banner -v verbose -qsv_device $Device `
        -f lavfi -i 'color=c=black:s=64x64:r=1' -t 0.1 -c:v h264_qsv -f null - 2>&1
    $text = ($out | Out-String)
    $m = [regex]::Match($text, 'Using device [0-9a-fA-F:]+ \((.*)\)')
    if ($m.Success) { return $m.Groups[1].Value }
    return "adapter $Device"
}

$adapters = @{}
foreach ($d in @('0', '1')) {
    $adapters[$d] = Get-QsvAdapterName -Device ([int]$d)
}

function Measure-Encode {
    param([string]$Path, [string]$Resolution, [string[]]$CodecArgs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $ff -hide_banner -v error -f lavfi -i "testsrc2=size=$Resolution`:rate=30" -t $Seconds @CodecArgs -f null - 2>$null | Out-Null
    $rc = $LASTEXITCODE
    $sw.Stop()
    return [pscustomobject]@{
        Path       = $Path
        Resolution = $Resolution
        Ok         = ($rc -eq 0)
        Ms         = [math]::Round($sw.Elapsed.TotalMilliseconds)
        Fps        = [math]::Round(($Seconds / $sw.Elapsed.TotalSeconds), 1)
    }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($res in $Resolutions) {
    $rows.Add((Measure-Encode -Path 'libx264 veryfast' -Resolution $res -CodecArgs @(
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20')))
    $rows.Add((Measure-Encode -Path "QSV 0: $($adapters['0'])" -Resolution $res -CodecArgs @(
        '-qsv_device', '0', '-c:v', 'h264_qsv', '-global_quality', '22')))
    $rows.Add((Measure-Encode -Path "QSV 1: $($adapters['1'])" -Resolution $res -CodecArgs @(
        '-qsv_device', '1', '-c:v', 'h264_qsv', '-global_quality', '22')))
}

if ($Json) {
    [pscustomobject]@{
        adapters = $adapters
        results  = $rows
        seconds  = $Seconds
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host ''
Write-Host 'QSV adapters' -ForegroundColor Cyan
foreach ($d in @('0', '1')) { Write-Host ("  {0}: {1}" -f $d, $adapters[$d]) }
Write-Host ''
$rows | Format-Table -AutoSize

$igpu1080 = $rows | Where-Object { $_.Resolution -eq '1920x1080' -and $_.Path -like 'QSV 1:*' } | Select-Object -First 1
$cpu1080 = $rows | Where-Object { $_.Resolution -eq '1920x1080' -and $_.Path -eq 'libx264 veryfast' } | Select-Object -First 1
if ($igpu1080 -and $cpu1080) {
    $ratio = [math]::Round($igpu1080.Ms / $cpu1080.Ms, 2)
    Write-Host ''
    Write-Host ("1080p: iGPU QSV is {0}x the libx264 time (lower is better)" -f $ratio)
    if ($ratio -gt 1.3) {
        Write-Host 'Verdict: keep libx264 for 1080p H.264; use the iGPU for display, not encoding.' -ForegroundColor Yellow
    } else {
        Write-Host 'Verdict: iGPU QSV is competitive for 1080p; it can offload the CPU.' -ForegroundColor Green
    }
}
Write-Host ''
