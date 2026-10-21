# b65.ps1 - single entry point for the B65 AI Workbench.
# Usage examples:
#   .\b65.ps1 setup
#   .\b65.ps1 install llm
#   .\b65.ps1 models -Profile draft
#   .\b65.ps1 llm start
#   .\b65.ps1 mode video
#   .\b65.ps1 status
#   .\b65.ps1 dashboard
#   .\b65.ps1 render -Profile draft -Image .\assets\products\module.png -Prompt "slow dolly-in, studio light"
#   .\b65.ps1 card -Data .\config\cards\example.json
#   .\b65.ps1 build -Manifest .\projects\iot-demo\manifest.json
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\B65.psm1') -Force

function Split-StepArgs {
    param([string[]]$Items = @())
    $named = @{}
    $positional = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        if ($item -match '^-([A-Za-z][A-Za-z0-9]*)$') {
            $key = $Matches[1]
            $nextIsValue = $false
            if ($i + 1 -lt $Items.Count) {
                $next = $Items[$i + 1]
                if (($next -notmatch '^-') -or ($next -match '^-?[0-9]+(\.[0-9]+)?$')) { $nextIsValue = $true }
            }
            if ($nextIsValue) {
                $named[$key] = $Items[$i + 1]
                $i++
            } else {
                $named[$key] = $true
            }
        } else {
            $positional += $item
        }
    }
    return [pscustomobject]@{ Named = $named; Positional = $positional }
}

function Invoke-Step {
    param([string]$Name, [string[]]$StepArgs = @())
    $path = Join-Path $PSScriptRoot "scripts\$Name.ps1"
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing script: $path" }
    $split = Split-StepArgs -Items $StepArgs
    $named = $split.Named
    $positional = $split.Positional
    & $path @named @positional
}

function Show-Help {
    Write-Host ''
    Write-Host 'B65 AI Workbench' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  setup                       create folders, fetch 7-Zip and FFmpeg'
    Write-Host '  install llm|video|all       download XeStrata and/or ComfyUI XPU'
    Write-Host '  models -Profile draft|final download video model weights'
    Write-Host '  llm start|stop|restart|status'
    Write-Host '  video start|stop|restart|status'
    Write-Host '  mode llm|video|idle         exclusive GPU mode switch'
    Write-Host '  status [-Json]              RAM/VRAM/process snapshot'
    Write-Host '  watch -Target llm|video     run the resource watchdog in this terminal'
    Write-Host '  dashboard                   local web console on port 8099'
    Write-Host '  render -Profile ... -Image ... -Prompt ...'
    Write-Host '  card -Data .\config\cards\example.json'
    Write-Host '  build -Manifest .\projects\iot-demo\manifest.json'
    Write-Host '  test-workflow -Profile draft'
    Write-Host '  doctor                      environment checks'
    Write-Host ''
}

switch ($Command.ToLowerInvariant()) {
    'help'      { Show-Help }
    'setup'     { Invoke-Step -Name 'Setup' -StepArgs $Rest }
    'install'   {
        $what = 'all'
        if ($Rest.Count -gt 0) { $what = $Rest[0] }
        $more = @()
        if ($Rest.Count -gt 1) { $more = $Rest[1..($Rest.Count - 1)] }
        switch ($what) {
            'llm'   { Invoke-Step -Name 'Install-Llm' -StepArgs $more }
            'video' { Invoke-Step -Name 'Install-Video' -StepArgs $more }
            'all'   { Invoke-Step -Name 'Install-Llm' -StepArgs $more; Invoke-Step -Name 'Install-Video' -StepArgs $more }
            default { throw "Unknown install target: $what" }
        }
    }
    'models'    { Invoke-Step -Name 'Download-Models' -StepArgs $Rest }
    'llm'       { Invoke-Step -Name 'Llm' -StepArgs $Rest }
    'video'     { Invoke-Step -Name 'Video' -StepArgs $Rest }
    'mode'      { Invoke-Step -Name 'Mode' -StepArgs $Rest }
    'status'    { Invoke-Step -Name 'Get-Status' -StepArgs $Rest }
    'watch'     { Invoke-Step -Name 'Watch-Resources' -StepArgs $Rest }
    'dashboard' { Invoke-Step -Name 'Start-Dashboard' -StepArgs $Rest }
    'render'    { Invoke-Step -Name 'Invoke-Render' -StepArgs $Rest }
    'card'      { Invoke-Step -Name 'New-SpecCard' -StepArgs $Rest }
    'build'     { Invoke-Step -Name 'Build-Video' -StepArgs $Rest }
    'test-workflow' { Invoke-Step -Name 'Test-Workflow' -StepArgs $Rest }
    'doctor'    { Invoke-Step -Name 'Doctor' -StepArgs $Rest }
    default     { Show-Help; throw "Unknown command: $Command" }
}
