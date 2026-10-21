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
$dest = Join-Path (Get-B65Path 'apps') 'ComfyUI_windows_portable'
$existing = Get-B65ComfyRoot
$complete = Join-Path $dest '.b65-comfy-install-complete'
$modelsZip = $null

if ($existing -and -not $Force) {
    $dest = $existing
    Write-B65Log "ComfyUI is already installed; keeping $dest" -Name 'setup'
} else {
    if ($existing) {
        Write-B65Log "Replacing the existing ComfyUI unpack with a fresh verified one" -Name 'setup' -Level WARN
    }
    Remove-Item Env:B65_INSTALL_CHILD -ErrorAction SilentlyContinue
    $parts = @('ComfyUI_Windows_portable_xpu.7z.001', 'ComfyUI_Windows_portable_xpu.7z.002')
    foreach ($p in $parts) {
        Invoke-B65Download -Uri "$ReleaseBase/$p" -OutFile (Join-Path $downloadDir $p) -Force:$Force -MinBytes 100000000
    }
    $modelsZip = Join-Path $downloadDir 'models.zip'
    Invoke-B65Download -Uri "$ReleaseBase/models.zip" -OutFile $modelsZip -Force:$Force

    foreach ($p in $parts) {
        if (-not (Test-B65Archive -Archive (Join-Path $downloadDir $p))) {
            throw "The ComfyUI archive failed validation: $p"
        }
    }
    if (-not (Test-B65Archive -Archive $modelsZip)) { throw "The ComfyUI model pack failed validation: $modelsZip" }

    $tmp = Join-Path (Get-B65Path 'apps') '_comfy_tmp'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        # 7-Zip follows the other split volumes from the same folder when it opens .7z.001.
        $seven = Get-B65SevenZip
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Write-B65Log "Extracting $(Join-Path $downloadDir $parts[0])" -Name 'setup'
        & $seven x (Join-Path $downloadDir $parts[0]) "-o$tmp" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed ($LASTEXITCODE) for the ComfyUI portable volumes; incomplete files are at $tmp" }
        $portable = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'python_embeded' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $portable) {
            $portable = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'python_embedded' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $portable) { throw 'python_embeded folder not found in the ComfyUI pack.' }
        if (-not (Test-Path -LiteralPath (Join-Path $portable.FullName 'python.exe'))) { throw "python.exe not found in the ComfyUI pack." }

        # Mark the new tree as incomplete until the optional model pack is expanded and linked.
        $sourceRoot = $portable.Parent.FullName
        $stagedComplete = Join-Path $sourceRoot '.b65-comfy-install-complete'
        if (Test-Path -LiteralPath $stagedComplete) { Remove-Item -LiteralPath $stagedComplete -Force }
        $backup = $null
        if (Test-Path -LiteralPath $dest) {
            $backup = $dest + '.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            try {
                Move-Item -LiteralPath $dest -Destination $backup -Force
                Move-Item -LiteralPath $sourceRoot -Destination $dest
            } catch {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
                    Move-Item -LiteralPath $backup -Destination $dest
                }
                throw
            }
        } else {
            Move-Item -LiteralPath $sourceRoot -Destination $dest
        }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
}

# Optional model pack (checkpoints, VAEs and helper models from the same project).
$comfyDir = Join-Path $dest 'ComfyUI'
if (Test-Path -LiteralPath $comfyDir) {
    if ($modelsZip -and (Test-Path -LiteralPath $modelsZip)) {
        Write-B65Log 'Extracting models.zip into the ComfyUI folder ...' -Name 'setup'
        try {
            Expand-B65Zip -Archive $modelsZip -Destination $comfyDir
        } catch {
            Write-B65Log ("The optional ComfyUI model pack could not be unpacked: " + $_.Exception.Message) -Level WARN -Name 'setup'
        }
    }
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
if (-not (Test-Path -LiteralPath $complete)) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($complete, ((Get-Date).ToString('o') + [Environment]::NewLine), $utf8)
}
