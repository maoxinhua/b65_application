# Use-LlmModel.ps1 - select an already-downloaded XeStrata model and persist it.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('IQ2_XS', 'IQ3_XXS', 'IQ3_S')][string]$Model,
    [int]$Context = 0,
    [int]$ResidentBudgetGiB = -1,
    [ValidateSet('auto', 'mmap', 'on')][string]$LowRam = '',
    [ValidateSet('int8', 'q4_0', 'k8v4')][string]$Kv = '',
    [int]$MaxOutputTokens = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$configPath = Join-Path (Get-B65Path 'config') 'llm.json'
$cfg = Read-B65Json -Path $configPath
$modelsDir = Resolve-B65Path -Path ([string]$cfg.modelsDir)
$modelDir = Join-Path $modelsDir $Model
$gguf = @(Get-ChildItem -LiteralPath $modelDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue)
if (-not $gguf -or $gguf.Count -eq 0) {
    throw "Model $Model is not downloaded in $modelDir. Run: .\b65.ps1 install llm -Model $Model -RunSetup -NoStart -SetDefault"
}

$cfg.model = $Model
$cfg | Add-Member -NotePropertyName modelAlias -NotePropertyValue ("13900_qwen3.8_flash_next_XEStrata_" + $Model) -Force
if ($Context -gt 0) { $cfg.context = $Context }
if ($LowRam) {
    $cfg.lowRam = $LowRam
} else {
    $cfg.lowRam = if ($Model -eq 'IQ2_XS') { 'auto' } else { 'mmap' }
}
if ($Kv) { $cfg | Add-Member -NotePropertyName kv -NotePropertyValue $Kv -Force }
if ($MaxOutputTokens -gt 0) { $cfg | Add-Member -NotePropertyName maxOutputTokens -NotePropertyValue $MaxOutputTokens -Force }
if ($ResidentBudgetGiB -ge 0) {
    $cfg | Add-Member -NotePropertyName residentBudgetGiB -NotePropertyValue ([int]$ResidentBudgetGiB) -Force
}
Write-B65Json -Path $configPath -Value $cfg

$profile = $null
if ($cfg.modelCatalog) { $profile = $cfg.modelCatalog.$Model }
$label = if ($profile) { [string]$profile.label } else { $Model }
$ram = if ($profile) { [int]$profile.ramGB } else { 0 }
$note = if ($profile) { [string]$profile.note } else { '' }
$sizeGB = [math]::Round((($gguf | Measure-Object Length -Sum).Sum / 1GB), 1)
Write-Host ''
Write-Host ("Model selected: {0}  ({1})" -f $Model, $label) -ForegroundColor Green
Write-Host ("  Files : {0} ({1} GB)" -f $modelDir, $sizeGB)
Write-Host ("  RAM   : ~{0} GB needed" -f $ram)
Write-Host ("  Note  : {0}" -f $note)
Write-Host ("  Config: {0}" -f $configPath)
Write-Host ''
