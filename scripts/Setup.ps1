# Setup.ps1 - create directories and fetch the portable tools used by the workbench.
# ASCII-only. Runs on Windows PowerShell 5.1 and PowerShell 7.
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

Write-B65Log 'B65 setup: tools' -Name 'setup'

$dirs = @(
    'apps', 'models', 'models\comfyui', 'models\comfyui\diffusion_models',
    'models\comfyui\text_encoders', 'models\comfyui\vae', 'models\comfyui\loras',
    'models\comfyui\upscale_models', 'tools', 'tools\7zip', 'tools\ffmpeg',
    'runtime', 'runtime\logs', 'runtime\build', 'output', 'output\cards',
    'output\shots', 'docs', 'projects'
)
foreach ($d in $dirs) {
    $full = Join-Path (Get-B65Root) $d
    if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Force -Path $full | Out-Null }
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'PowerShell 5.1 or newer is required.'
}

# 7-Zip standalone (7zr.exe) - enough for .7z and split volumes.
$sevenZip = Join-Path (Get-B65Path 'tools\7zip') '7zr.exe'
if ((-not (Test-Path -LiteralPath $sevenZip)) -or $Force) {
    Invoke-B65Download -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $sevenZip -Force:$Force -MinBytes 100000
}

# FFmpeg essentials (portable).
$ffmpegExe = Join-Path (Get-B65Path 'tools\ffmpeg') 'bin\ffmpeg.exe'
if ((-not (Test-Path -LiteralPath $ffmpegExe)) -or $Force) {
    $zip = Join-Path (Get-B65Path 'tools') 'ffmpeg-essentials.zip'
    Invoke-B65Download -Uri 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip -Force:$Force -MinBytes 30000000
    $tmp = Join-Path (Get-B65Path 'tools') '_ffmpeg_tmp'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $src) { throw 'ffmpeg.exe not found in the downloaded archive.' }
    $binDir = Join-Path (Get-B65Path 'tools\ffmpeg') 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Copy-Item -LiteralPath $src.FullName -Destination (Join-Path $binDir 'ffmpeg.exe') -Force
    $probe = Join-Path $src.DirectoryName 'ffprobe.exe'
    if (Test-Path -LiteralPath $probe) { Copy-Item -LiteralPath $probe -Destination (Join-Path $binDir 'ffprobe.exe') -Force }
    Remove-Item -LiteralPath $tmp -Recurse -Force
    Remove-Item -LiteralPath $zip -Force
}

# Intel xpu-smi: GPU temperature/power. Sysman needs an elevated shell at runtime.
$xpuDir = Join-Path (Get-B65Path 'tools') 'xpu-smi'
$xpuExe = Get-ChildItem -LiteralPath $xpuDir -Recurse -Filter 'xpu-smi.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ((-not $xpuExe) -or $Force) {
    $xpuZip = Join-Path (Get-B65Path 'tools') 'xpu-smi.zip'
    Invoke-B65Download -Uri 'https://github.com/intel/xpumanager/releases/download/v2.3.0/xpu-smi_2.3.0-8fd5dca_win_2022.zip' -OutFile $xpuZip -MinBytes 500000 -Force:$Force
    if (Test-Path -LiteralPath $xpuDir) { Remove-Item -LiteralPath $xpuDir -Recurse -Force }
    Expand-Archive -LiteralPath $xpuZip -DestinationPath $xpuDir -Force
    Remove-Item -LiteralPath $xpuZip -Force
}

# Report versions.
$ff = Get-B65Ffmpeg
Write-B65Log ("ffmpeg: " + $ff) -Name 'setup'
& $ff -version | Select-Object -First 1

Write-B65Log 'Tools ready. Next: scripts\Install-Llm.ps1 and scripts\Install-Video.ps1' -Name 'setup'
