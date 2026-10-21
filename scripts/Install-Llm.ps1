# Install-Llm.ps1 - download and unpack XeStrata (Intel Arc, Windows).
# The official Strata build has no Intel engine on Windows; XeStrata is the supported path.
[CmdletBinding()]
param(
    [string]$Version = 'xe0.1.45-1',
    [switch]$Force,
    [switch]$RunSetup
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$asset = "XeStrata-$Version-windows-x64.7z"
$url = "https://github.com/MistVVK/XeStrata/releases/download/$Version/$asset"
$downloadDir = Join-Path (Get-B65Path 'apps') '_download'
$archive = Join-Path $downloadDir $asset
$dest = Join-Path (Get-B65Path 'apps') 'XeStrata'

Write-B65Log "Installing XeStrata $Version" -Name 'setup'
Invoke-B65Download -Uri $url -OutFile $archive -Force:$Force -MinBytes 50000000

if (Test-Path -LiteralPath $dest) {
    if (-not $Force) { throw "Destination already exists: $dest (use -Force to reinstall)" }
    Remove-Item -LiteralPath $dest -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Expand-B65SevenZip -Archive $archive -Destination $dest

# Normalise: if the archive has a single subfolder, flatten it.
$cli = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'xestrata-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cli) {
    $gui = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'xestrata.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gui) { throw "xestrata-cli.exe not found under $dest" }
    $cli = $gui
}
if ($cli.DirectoryName -ne $dest) {
    Write-B65Log "Flattening $($cli.DirectoryName) -> $dest" -Name 'setup'
    Get-ChildItem -LiteralPath $cli.DirectoryName -Force | Move-Item -Destination $dest -Force
}

$exe = Join-Path $dest 'xestrata-cli.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "xestrata-cli.exe still missing after flatten: $exe" }

# Probe the runtime. A missing .NET runtime produces a specific Windows error.
Write-B65Log 'Probing xestrata-cli.exe ...' -Name 'setup'
try {
    $probe = & $exe --version 2>&1
} catch {
    $probe = @($_.Exception.Message)
}
Write-B65Log ("Probe output: " + ($probe -join ' ')) -Name 'setup'

Write-Host ''
Write-Host 'XeStrata unpacked to:' $dest
Write-Host ''
Write-Host 'One-time setup (required before the control scripts can start it):'
Write-Host '  1. Install .NET 10 Desktop Runtime and the VC++ x64 redistributable if missing.'
Write-Host '     https://dotnet.microsoft.com/download/dotnet/10.0'
Write-Host '     https://aka.ms/vs/17/release/vc_redist.x64.exe'
Write-Host '  2. Run apps\XeStrata\xestrata.exe once.'
Write-Host '     - GPU: Intel Arc Pro B65 / bmg-g31'
Write-Host '     - Model: IQ2_XS (64 GB RAM is the limiting factor)'
Write-Host '     - Context: 32768'
Write-Host '     - Images: off for now'
Write-Host '  3. Come back and run: .\b65.ps1 llm start'
Write-Host ''

if ($RunSetup) {
    $gui = Join-Path $dest 'xestrata.exe'
    if (Test-Path -LiteralPath $gui) { Start-Process -FilePath $gui -WorkingDirectory $dest }
}
