# Get-Status.ps1 - human or JSON snapshot of the workbench.
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$s = Get-B65Status
if ($Json) {
    $s | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host '=== B65 Workbench ===' -ForegroundColor Cyan
Write-Host ("Mode        : {0}" -f $s.mode)
Write-Host ("RAM         : {0} GB free / {1} GB ({2}% used)" -f $s.memory.FreeGB, $s.memory.TotalGB, $s.memory.UsedPct)
Write-Host ("Page file   : {0} MB / {1} MB ({2}%)" -f $s.memory.PageFileUsedMB, $s.memory.PageFileTotalMB, $s.memory.PageFilePct)
Write-Host ("GPU         : {0}" -f $s.gpu.Name)
Write-Host ("VRAM        : {0} MB dedicated, {1} MB shared, {2}% util" -f $s.gpu.DedicatedMB, $s.gpu.SharedMB, $s.gpu.UtilPct)
Write-Host ''
Write-Host ("LLM         : {0}  pid={1}  port={2}  model={3}  ctx={4}" -f `
    $(if ($s.llm.running) { 'RUNNING' } else { 'stopped' }), $s.llm.pid, $s.llm.port, $s.llm.model, $s.llm.context)
if ($s.llm.running) {
    Write-Host ("              RSS {0} MB, GPU {1} MB, CPU {2}s" -f $s.llm.stats.WorkingSetMB, $s.llm.vramMB, $s.llm.stats.CpuSec)
}
Write-Host ("Video       : {0}  pid={1}  port={2}" -f `
    $(if ($s.video.running) { 'RUNNING' } else { 'stopped' }), $s.video.pid, $s.video.port)
if ($s.video.running) {
    Write-Host ("              RSS {0} MB, GPU {1} MB, CPU {2}s" -f $s.video.stats.WorkingSetMB, $s.video.vramMB, $s.video.stats.CpuSec)
}
if ($s.watchdog) {
    Write-Host ("Watchdog    : {0}  action={1}  free={2} GB" -f $s.watchdog.target, $s.watchdog.action, $s.watchdog.memory.FreeGB)
}
Write-Host ''
if ($s.llm.running) {
    Write-Host ("API (LAN)   : http://{0}:{1}/v1" -f (Get-B65LanIp), $s.llm.port)
    Write-Host ("API key     : {0}" -f $s.llm.apiKey)
}
Write-Host ("ComfyUI     : http://127.0.0.1:{0}" -f $s.video.port)
Write-Host ''
