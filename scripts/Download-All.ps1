# Download-All.ps1 - sequential, resumable download queue (video first, LLM last).
[CmdletBinding()]
param(
    [switch]$SkipFinal,
    [switch]$SkipLlm,
    [switch]$SkipDraft
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$queue = New-Object System.Collections.Generic.List[object]
if (-not $SkipDraft) {
    $queue.Add([pscustomobject]@{ Name = 'video-draft'; Script = 'Download-Models.ps1'; Args = @{ Profile = 'draft' } })
}
if (-not $SkipFinal) {
    $queue.Add([pscustomobject]@{ Name = 'video-final'; Script = 'Download-Models.ps1'; Args = @{ Profile = 'final' } })
}
if (-not $SkipLlm) {
    $queue.Add([pscustomobject]@{ Name = 'llm-iq2-xs'; Script = 'Install-Llm.ps1'; Args = @{ RunSetup = $true } })
}

Write-B65Log ("Download queue: " + (($queue | ForEach-Object { $_.Name }) -join ' -> ')) -Name 'download-all'

foreach ($step in $queue) {
    Write-B65Log ("=== START {0} ===" -f $step.Name) -Name 'download-all'
    $started = Get-Date
    try {
        $named = $step.Args
        & (Join-Path $PSScriptRoot $step.Script) @named
        $elapsed = (Get-Date) - $started
        Write-B65Log ("=== DONE {0} in {1:hh\:mm\:ss} ===" -f $step.Name, $elapsed) -Name 'download-all'
    } catch {
        Write-B65Log ("=== FAILED {0}: {1} ===" -f $step.Name, $_.Exception.Message) -Level ERROR -Name 'download-all'
        Write-B65Log 'Queue stopped. Fix the error and run this script again; partial files resume.' -Level WARN -Name 'download-all'
        break
    }
}

Write-B65Log 'Download queue finished.' -Name 'download-all'
