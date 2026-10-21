# Mode.ps1 - exclusive mode switch (LLM vs video) for a single 32 GB GPU.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('llm', 'video', 'idle')][string]$Target
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$mutex = Enter-B65Lock
try {
    Write-B65Log "Switching mode -> $Target" -Name 'mode'

    # Always stop both first: the card cannot host both working sets.
    & (Join-Path $PSScriptRoot 'Llm.ps1') -Action stop
    & (Join-Path $PSScriptRoot 'Video.ps1') -Action stop

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $gpu = Get-B65Gpu
        if ($gpu.DedicatedMB -lt 2048) { break }
        Start-Sleep -Seconds 2
    }

    switch ($Target) {
        'llm'   { & (Join-Path $PSScriptRoot 'Llm.ps1') -Action start }
        'video' { & (Join-Path $PSScriptRoot 'Video.ps1') -Action start }
        'idle'  {
            $state = Get-B65State
            $state.mode = 'idle'
            Save-B65State -State $state
            Write-B65Log 'Both engines stopped.' -Name 'mode'
        }
    }
} finally {
    Exit-B65Lock -Mutex $mutex
}
