# Download-Models.ps1 - fetch ComfyUI video models into models\comfyui.
[CmdletBinding()]
param(
    [ValidateSet('all', 'draft', 'final')][string]$Profile = 'draft',
    [string]$Endpoint = '',
    [string[]]$Only = @(),
    [switch]$IncludeOptional,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$manifest = Read-B65Json -Path (Join-Path (Get-B65Path 'config') 'models.json')
if (-not $Endpoint) { $Endpoint = $manifest.endpoint }
$Endpoint = $Endpoint.TrimEnd('/')

$draftIds = @('wan22-ti2v-5b', 'umt5-xxl', 'wan22-vae')
$finalIds = @('wan22-i2v-14b-high', 'wan22-i2v-14b-low', 'wan22-i2v-4step-high', 'wan22-i2v-4step-low', 'umt5-xxl', 'wan21-vae', 'hunyuan-1080p-sr')

$selected = @()
foreach ($f in $manifest.files) {
    if ($Only.Count -gt 0) {
        if ($Only -notcontains $f.id) { continue }
    } else {
        if ($Profile -eq 'draft' -and ($draftIds -notcontains $f.id)) { continue }
        if ($Profile -eq 'final' -and ($finalIds -notcontains $f.id)) { continue }
        if ($f.optional -and (-not $IncludeOptional)) { continue }
    }
    $selected += $f
}

if ($selected.Count -eq 0) {
    Write-B65Log 'No models selected.' -Name 'models'
    return
}

$totalGB = 0
foreach ($f in $selected) {
    $target = Resolve-B65Path -Path $f.target
    $expected = [double]$f.sizeGB
    if ((Test-Path -LiteralPath $target) -and (-not $Force)) {
        $actual = (Get-Item -LiteralPath $target).Length / 1GB
        if ($actual -ge ($expected * 0.9)) {
            Write-B65Log ("Skip {0} ({1:N1} GB present)" -f $f.id, $actual) -Name 'models'
            continue
        }
        Write-B65Log ("Partial {0} ({1:N1} GB), resuming" -f $f.id, $actual) -Name 'models'
    }
    Write-B65Log ("Fetch {0}: {1} / {2}" -f $f.id, $f.repo, $f.file) -Name 'models'
    $minBytes = [long]($expected * 0.6 * 1GB)
    $endpoints = @($Endpoint)
    if ($Endpoint -match 'hf-mirror') { $endpoints += 'https://huggingface.co' }
    $lastError = $null
    foreach ($ep in $endpoints) {
        $url = "{0}/{1}/resolve/main/{2}?download=true" -f $ep, $f.repo, $f.file
        try {
            Invoke-B65Download -Uri $url -OutFile $target -Force:$Force -MinBytes $minBytes
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Write-B65Log ("Endpoint failed: {0} ({1})" -f $ep, $_.Exception.Message) -Level WARN -Name 'models'
        }
    }
    if ($lastError) { throw $lastError }
    $size = (Get-Item -LiteralPath $target).Length / 1GB
    $totalGB += $size
}

Write-B65Log ("Model step complete. New data: {0:N1} GB" -f $totalGB) -Name 'models'
