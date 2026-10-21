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

    # .002 is a continuation volume, not a standalone archive: validate the set via .001 only.
    foreach ($p in $parts) {
        $partPath = Join-Path $downloadDir $p
        if (-not (Test-Path -LiteralPath $partPath)) { throw "Missing ComfyUI volume: $partPath" }
    }
    $firstPart = Join-Path $downloadDir $parts[0]
    if (-not (Test-B65Archive -Archive $firstPart)) { throw "The ComfyUI archive failed validation: $firstPart" }
    if (-not (Test-B65Archive -Archive $modelsZip)) { throw "The ComfyUI model pack failed validation: $modelsZip" }

    # Extract to a short path first: the pack contains torch license paths deeper
    # than MAX_PATH, and 7-Zip/Remove-Item fail under apps\...\ when they are long.
    $drive = Split-Path -Qualifier (Get-B65Root)
    $stage = Join-Path $drive 'b65c'
    if (Test-Path -LiteralPath $stage) { [System.IO.Directory]::Delete("\\?\$stage", $true) }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    try {
        # 7-Zip follows the other split volumes from the same folder when it opens .7z.001.
        $seven = Get-B65SevenZip
        Write-B65Log "Extracting $(Join-Path $downloadDir $parts[0]) to $stage" -Name 'setup'
        & $seven x (Join-Path $downloadDir $parts[0]) "-o$stage" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed ($LASTEXITCODE) for the ComfyUI portable volumes; incomplete files are at $stage" }

        $portable = $null
        foreach ($name in @('python_standalone', 'python_embeded', 'python_embedded')) {
            $portable = Get-ChildItem -LiteralPath $stage -Recurse -Directory -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($portable) { break }
        }
        if (-not $portable) { throw 'No python_standalone / python_embeded folder found in the ComfyUI pack.' }
        if (-not (Test-Path -LiteralPath (Join-Path $portable.FullName 'python.exe'))) { throw 'python.exe not found in the ComfyUI pack.' }

        $sourceRoot = $portable.Parent.FullName
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'ComfyUI\main.py'))) {
            throw "ComfyUI\main.py not found in $sourceRoot"
        }

        # Mark the new tree as incomplete until the optional model pack is expanded and linked.
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
                    if (Test-Path -LiteralPath $dest) { [System.IO.Directory]::Delete("\\?\$dest", $true) }
                    Move-Item -LiteralPath $backup -Destination $dest
                }
                throw
            }
        } else {
            Move-Item -LiteralPath $sourceRoot -Destination $dest
        }
        if ($backup -and (Test-Path -LiteralPath $backup)) { [System.IO.Directory]::Delete("\\?\$backup", $true) }
    } finally {
        if (Test-Path -LiteralPath $stage) { [System.IO.Directory]::Delete("\\?\$stage", $true) }
    }
}

# Optional model pack (checkpoints, VAEs and helper models from the same project).
$comfyDir = Join-Path $dest 'ComfyUI'
if (Test-Path -LiteralPath $comfyDir) {
    if ($modelsZip -and (Test-Path -LiteralPath $modelsZip)) {
        Write-B65Log 'Extracting models.zip into a staging folder ...' -Name 'setup'
        $modelTmp = Join-Path (Get-B65Path 'apps') '_comfy_models_tmp'
        try {
            if (Test-Path -LiteralPath $modelTmp) { Remove-Item -LiteralPath $modelTmp -Recurse -Force }
            Expand-B65Zip -Archive $modelsZip -Destination $modelTmp
            $srcModels = Get-ChildItem -LiteralPath $modelTmp -Recurse -Directory -Filter 'models' -ErrorAction SilentlyContinue |
                Where-Object { $_.Parent.Name -eq 'ComfyUI' } | Select-Object -First 1
            if (-not $srcModels) {
                $srcModels = Get-ChildItem -LiteralPath $modelTmp -Recurse -Directory -Filter 'models' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if ($srcModels) {
                $dstModels = Join-Path $comfyDir 'models'
                New-Item -ItemType Directory -Force -Path $dstModels | Out-Null
                Copy-Item -Path (Join-Path $srcModels.FullName '*') -Destination $dstModels -Recurse -Force
                Write-B65Log ("Merged model pack from {0}" -f $srcModels.FullName) -Name 'setup'
            } else {
                Write-B65Log 'The model pack did not contain a models folder; skipped.' -Level WARN -Name 'setup'
            }
        } catch {
            Write-B65Log ("The optional ComfyUI model pack could not be unpacked: " + $_.Exception.Message) -Level WARN -Name 'setup'
        } finally {
            if (Test-Path -LiteralPath $modelTmp) { Remove-Item -LiteralPath $modelTmp -Recurse -Force }
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
