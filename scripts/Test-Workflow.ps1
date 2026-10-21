# Test-Workflow.ps1 - validate a workflow against the running ComfyUI /object_info.
[CmdletBinding()]
param(
    [ValidateSet('draft', 'final')][string]$Profile = 'draft',
    [string]$File = '',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$workflowPath = $File
if (-not $workflowPath) {
    $profileCfg = Read-B65Json -Path (Join-Path (Get-B65Path 'config\profiles') "video.$Profile.json")
    $workflowPath = Resolve-B65Path -Path $profileCfg.workflow
}
$workflowPath = Resolve-B65Path -Path $workflowPath
if (-not (Test-Path -LiteralPath $workflowPath)) { throw "Workflow not found: $workflowPath" }
$workflow = Read-B65Json -Path $workflowPath

$videoCfg = Get-B65Config -Name video
if (-not (Test-B65Port -Port ([int]$videoCfg.port))) {
    if ($Start) {
        & (Join-Path $PSScriptRoot 'Video.ps1') -Action start
    } else {
        throw 'ComfyUI is not running. Start it first or add -Start.'
    }
}

Write-B65Log "Validating $workflowPath" -Name 'workflow'
$result = Test-B65Workflow -Workflow $workflow
if ($result.Ok) {
    Write-Host 'Workflow OK: all node classes and inputs exist in this ComfyUI build.' -ForegroundColor Green
} else {
    Write-Host 'Workflow has issues:' -ForegroundColor Yellow
    foreach ($i in $result.Issues) { Write-Host "  - $i" }
    Write-Host ''
    Write-Host 'Tip: export the official template from ComfyUI (Workflow -> Export (API))'
    Write-Host 'and compare node IDs with config/profiles/video.<profile>.json.'
}
