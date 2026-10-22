# Start-Panel.ps1 - open the WinForms control panel (STA is required).
[CmdletBinding()]
param([string]$Tab = 'LLM')

$root = Split-Path -Parent $PSScriptRoot
$panel = Join-Path $root 'app\B65Panel.ps1'
if (-not (Test-Path -LiteralPath $panel)) { throw "Panel not found: $panel" }

$argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $panel + '"'))
if ($Tab) { $argList += @('-Tab', ('"' + $Tab + '"')) }
Start-Process -FilePath 'powershell.exe' -ArgumentList $argList | Out-Null
Write-Host "B65 Workbench panel launched (tab: $Tab)"
