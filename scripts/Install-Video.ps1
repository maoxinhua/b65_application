# Install-Video.ps1 - download and unpack the ComfyUI Intel XPU Windows portable pack.
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$ReleaseBase = 'https://github.com/YanWenKun/ComfyUI-WinPortable-XPU/releases/latest/download'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$downloadDir = Join-Path (Get-B65Path 'apps') '_download\comfy'
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$parts = @('ComfyUI_Windows_portable_xpu.7z.001', 'ComfyUI_Windows_portable_xpu.7z.002')
foreach ($p in $parts) {
    Invoke-B65Download -Uri "$ReleaseBase/$p" -OutFile (Join-Path $downloadDir $p) -Force:$Force -MinBytes 100000000
}
$modelsZip = Join-Path $downloadDir 'models.zip'
Invoke-B65Download -Uri "$ReleaseBase/models.zip" -OutFile $modelsZip -Force:$Force -MinBytes 100000000

$tmp = Join-Path (Get-B65Path 'apps') '_comfy_tmp'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Expand-B65SevenZip -Archive (Join-Path $downloadDir $parts[0]) -Destination $tmp

$portable = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'python_embeded' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $portable) {
    $portable = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'python_embedded' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $portable) { throw 'python_embeded folder not found in the ComfyUI pack.' }

$sourceRoot = $portable.Parent.FullName
$dest = Join-Path (Get-B65Path 'apps') 'ComfyUI_windows_portable'
if (Test-Path -LiteralPath $dest) {
    if (-not $Force) { throw "Destination already exists: $dest (use -Force to reinstall)" }
    Remove-Item -LiteralPath $dest -Recurse -Force
}
Move-Item -LiteralPath $sourceRoot -Destination $dest
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }

# Optional model pack (checkpoints, VAEs and helper models from the same project).
$comfyDir = Join-Path $dest 'ComfyUI'
if (Test-Path -LiteralPath $comfyDir) {
    Write-B65Log 'Extracting models.zip into the ComfyUI folder ...' -Name 'setup'
    Expand-Archive -LiteralPath $modelsZip -DestinationPath $comfyDir -Force
}

# Make ComfyUI read the shared model tree outside apps/.
$modelRoot = (Get-B65Path 'models\comfyui') -replace '\\', '/'
$yaml = @"
b65:
  base_path: $modelRoot
  diffusion_models: diffusion_models
  text_encoders: text_encoders
  vae: vae
  loras: loras
  upscale_models: upscale_models
"@
$yamlPath = Join-Path $comfyDir 'extra_model_paths.yaml'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($yamlPath, $yaml, $utf8)

Write-Host ''
Write-Host 'ComfyUI Intel XPU unpacked to:' $dest
Write-Host 'Shared model paths:' $yamlPath
Write-Host 'Next: .\b65.ps1 models -Profile draft'
Write-Host ''
