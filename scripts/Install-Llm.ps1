# Install-Llm.ps1 - download and unpack XeStrata (Intel Arc, Windows).
# The official Strata build has no Intel engine on Windows; XeStrata is the supported path.
[CmdletBinding()]
param(
    [string]$Version = 'xe0.1.45-1',
    [switch]$Force,
    [switch]$Interact,
    [switch]$CheckUpdate,
    [switch]$RunSetup,
    [string]$Model = 'IQ2_XS',
    [int]$Context = 32768,
    [string]$Source = 'modelscope',
    [string]$ModelsDir = '',
    [string]$DataDir = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$assetVersion = $Version -replace '^xe', ''
$asset = "XeStrata-$assetVersion-windows-x64.7z"
$url = "https://github.com/MistVVK/XeStrata/releases/download/$Version/$asset"
$downloadDir = Join-Path (Get-B65Path 'apps') '_download'
$archive = Join-Path $downloadDir $asset
$dest = Join-Path (Get-B65Path 'apps') 'XeStrata'
$exe = Join-Path $dest 'xestrata-cli.exe'

if ((Test-Path -LiteralPath $exe) -and -not $Force) {
    Write-B65Log "XeStrata is already installed; keeping $dest" -Name 'setup'
    if ($CheckUpdate) {
        try {
            $probeArgs = if ($env:B65_INSTALL_CHILD) { @('--check-update') } else { @('--describe') }
            $raw = (& $exe @probeArgs 2>&1 | Out-String)
            $probeExitCode = $LASTEXITCODE
            if ($env:B65_INSTALL_CHILD) { Write-Host $raw.Trim() } elseif ($probeExitCode -eq 0) {
                $desc = $raw | ConvertFrom-Json
                $gpuName = 'unknown'
                if ($desc.gpus -and $desc.gpus.Count -gt 0) { $gpuName = [string]$desc.gpus[0].name }
                Write-B65Log ("XeStrata {0}; GPU: {1}; RAM: {2} GB; AVX2: {3}" -f $desc.version, $gpuName, $desc.ram_gb, $desc.cpu.avx2) -Name 'setup'
            }
            if ($probeExitCode -ne 0) {
                Write-B65Log "The installed XeStrata version check failed; keeping the current engine" -Level WARN -Name 'setup'
            }
        } catch {
            Write-B65Log ("The installed version could not be checked: " + $_.Exception.Message) -Level WARN -Name 'setup'
        }
    }
} else {
    Remove-Item Env:B65_INSTALL_CHILD -ErrorAction SilentlyContinue
    Write-B65Log "Installing XeStrata $Version" -Name 'setup'
    Invoke-B65Download -Uri $url -OutFile $archive -Force:$Force
    if (-not (Test-B65Archive -Archive $archive)) {
        throw "The XeStrata archive failed validation: $archive"
    }

    # Extract beside the existing installation, then replace it only after a complete unpack.
    $staging = Join-Path (Get-B65Path 'apps') ('_xestrata_install_' + [guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        Expand-B65SevenZip -Archive $archive -Destination $staging
        # Normalise: if the archive has a single subfolder, flatten it.
        $cli = Get-ChildItem -LiteralPath $staging -Recurse -Filter 'xestrata-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cli) {
            $gui = Get-ChildItem -LiteralPath $staging -Recurse -Filter 'xestrata.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $gui) { throw "xestrata-cli.exe not found after extracting $archive" }
            $cli = $gui
        }
        if ($cli.DirectoryName -ne $staging) {
            Write-B65Log "Flattening $($cli.DirectoryName) -> $staging" -Name 'setup'
            Get-ChildItem -LiteralPath $cli.DirectoryName -Force | Move-Item -Destination $staging -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $staging 'xestrata-cli.exe'))) {
            throw "xestrata-cli.exe is missing from the extracted XeStrata archive"
        }
        if (Test-Path -LiteralPath $dest) {
            $backup = $dest + '.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            try {
                Move-Item -LiteralPath $dest -Destination $backup -Force
                Move-Item -LiteralPath $staging -Destination $dest
            } catch {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
                    Move-Item -LiteralPath $backup -Destination $dest
                }
                throw
            }
        } else {
            Move-Item -LiteralPath $staging -Destination $dest
        }
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

if (-not (Test-Path -LiteralPath $exe)) {
    $nested = Get-ChildItem -LiteralPath $dest -Filter 'xestrata-cli.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nested) { throw "XeStrata CLI not found under $dest; reinstall with: .\b65.ps1 install llm -Force" }
    Write-B65Log "Flattening the existing install: $($nested.DirectoryName) -> $dest" -Name 'setup'
    Get-ChildItem -LiteralPath $nested.DirectoryName -Force | Move-Item -Destination $dest -Force
}

# Probe the runtime when the engine was installed or checked on its own.
# In a child call (such as install all) the previous stage has already probed it.
if (-not $env:B65_INSTALL_CHILD) {
    Write-B65Log 'Probing xestrata-cli.exe ...' -Name 'setup'
    try {
        $raw = (& $exe --describe 2>&1 | Out-String)
        $desc = $raw | ConvertFrom-Json
        $gpuName = 'unknown'
        if ($desc.gpus -and $desc.gpus.Count -gt 0) { $gpuName = [string]$desc.gpus[0].name }
        Write-B65Log ("XeStrata {0}; GPU: {1}; RAM: {2} GB; AVX2: {3}" -f $desc.version, $gpuName, $desc.ram_gb, $desc.cpu.avx2) -Name 'setup'
    } catch {
        Write-B65Log ("Describe probe failed: " + $_.Exception.Message) -Level WARN -Name 'setup'
    }
}

if (-not $RunSetup) {
    if (-not $env:B65_INSTALL_CHILD) {
        Write-Host ''
        Write-Host 'XeStrata is ready at:' $dest
        Write-Host ''
        Write-Host 'One-time model setup (required before the control scripts can start it):'
        Write-Host '  1. Install .NET 10 Desktop Runtime and the VC++ x64 redistributable if missing.'
        Write-Host '     https://dotnet.microsoft.com/download/dotnet/10.0'
        Write-Host '     https://aka.ms/vs/17/release/vc_redist.x64.exe'
        Write-Host '  2. Either run the CLI setup (recommended, keeps models in the workspace):'
        Write-Host '       .\b65.ps1 install llm -RunSetup'
        Write-Host '     or run apps\XeStrata\xestrata.exe once and choose:'
        Write-Host '       GPU: Intel Arc Pro B65 / bmg-g31'
        Write-Host '       Model: IQ2_XS (64 GB RAM is the limiting factor)'
        Write-Host '       Context: 32768'
        Write-Host '       Images: off for now'
        Write-Host '  3. Then run: .\b65.ps1 llm start'
        Write-Host ''
    }
}

if ($RunSetup) {
    if (-not $ModelsDir) { $ModelsDir = [string](Get-B65Config -Name llm).modelsDir }
    if (-not $DataDir) { $DataDir = [string](Get-B65Config -Name llm).dataDir }
    $modelsFull = Resolve-B65Path -Path $ModelsDir
    $dataFull = Resolve-B65Path -Path $DataDir
    New-Item -ItemType Directory -Force -Path $modelsFull | Out-Null
    New-Item -ItemType Directory -Force -Path $dataFull | Out-Null
    Write-Host ''
    Write-Host "Starting XeStrata setup: model=$Model context=$Context source=$Source" -ForegroundColor Yellow
    Write-Host "Models: $modelsFull"
    Write-Host "Data:   $dataFull"
    Write-Host "This downloads roughly 68 GB and prepares the engine; it can be resumed."
    $setupArgs = @(
        '--setup', '--family', 'qwen',
        '--model', $Model,
        '--context', [string]$Context,
        '--vision', 'no',
        '--source', $Source,
        '--models-dir', $modelsFull,
        '--data-dir', $dataFull,
        '--no-browser'
    )
    if (-not $Interact) { $setupArgs += '--yes' }
    $oldErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @setupArgs
        $setupExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorPreference
    }
    if ($setupExitCode -ne 0) {
        throw "XeStrata model setup failed with exit code $setupExitCode. Keep the existing engine and models; rerun the same command to resume."
    }
    Remove-Item Env:B65_INSTALL_CHILD -ErrorAction SilentlyContinue
}
