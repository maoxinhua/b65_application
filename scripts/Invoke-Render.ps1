# Invoke-Render.ps1 - submit a Wan2.2 workflow to ComfyUI and collect the result.
[CmdletBinding()]
param(
    [ValidateSet('draft', 'final')][string]$Profile = '',
    [string]$Image = '',
    [string]$Prompt = '',
    [string]$JobFile = '',
    [string]$Negative = '',
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Frames = 0,
    [int]$Steps = 0,
    [double]$Cfg = -1,
    [int]$Seed = -1,
    [string]$OutDir = 'output\shots',
    [string]$Name = '',
    [int]$TimeoutSec = 0,
    [switch]$NoStart,
    [switch]$SkipValidate
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

if ($JobFile) {
    $jobPath = Resolve-B65Path -Path $JobFile
    if (-not (Test-Path -LiteralPath $jobPath)) { throw "Job file not found: $jobPath" }
    $jobData = Read-B65Json -Path $jobPath
    if ($jobData.profile) { $Profile = [string]$jobData.profile }
    if ($jobData.image) { $Image = [string]$jobData.image }
    if ($jobData.prompt) { $Prompt = [string]$jobData.prompt }
    if ($jobData.negative) { $Negative = [string]$jobData.negative }
    if ($jobData.name) { $Name = [string]$jobData.name }
}
if (-not $Image) { throw 'Image is required (or provide -Job with an image path).' }
if (-not $Prompt) { throw 'Prompt is required (or provide -Job with a prompt).' }
Write-B65Log ("Render requested: profile={0} image={1}" -f $Profile, $Image) -Name 'render'

$settings = Get-B65Config -Name settings
if (-not $Profile) { $Profile = [string]$settings.video.defaultProfile }
$profileCfg = Read-B65Json -Path (Join-Path (Get-B65Path 'config\profiles') "video.$Profile.json")
$workflowPath = Resolve-B65Path -Path $profileCfg.workflow
if (-not (Test-Path -LiteralPath $workflowPath)) { throw "Workflow not found: $workflowPath" }
$workflow = Read-B65Json -Path $workflowPath

$imagePath = Resolve-B65Path -Path $Image
if (-not (Test-Path -LiteralPath $imagePath)) { throw "Input image not found: $imagePath" }

# Apply parameters (CLI overrides profile defaults).
$p = $profileCfg.params
$w = if ($Width -gt 0) { $Width } else { [int]$p.width }
$h = if ($Height -gt 0) { $Height } else { [int]$p.height }
$f = if ($Frames -gt 0) { $Frames } else { [int]$p.frames }
$st = if ($Steps -gt 0) { $Steps } else { [int]$p.steps }
$cfgValue = if ($Cfg -ge 0) { $Cfg } else { [double]$p.cfg }
$seedValue = if ($Seed -ge 0) { $Seed } else { Get-Random -Minimum 1 -Maximum 2147483647 }
$timeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { [int]$profileCfg.timeoutSec }

$map = $profileCfg.map
function Set-Mapped {
    param([string]$Key, $Value)
    $m = $map.$Key
    if ($m) { Set-B65WorkflowValue -Workflow $workflow -NodeId $m.node -InputName $m.input -Value $Value }
}

Set-Mapped 'positive' $Prompt
if ($Negative) { Set-Mapped 'negative' $Negative }
Set-Mapped 'width' $w
Set-Mapped 'height' $h
Set-Mapped 'frames' $f
Set-Mapped 'steps' $st
Set-Mapped 'cfg' $cfgValue
Set-Mapped 'seed' $seedValue
Set-Mapped 'endSteps' $st
Set-Mapped 'endCfg' $cfgValue
Set-Mapped 'endSeed' $seedValue

# Copy the image into ComfyUI's input folder.
$comfyRoot = Get-B65ComfyRoot
if (-not $comfyRoot) { throw 'ComfyUI not installed. Run .\b65.ps1 install video.' }
$inputDir = Join-Path $comfyRoot 'ComfyUI\input'
if (-not (Test-Path -LiteralPath $inputDir)) { New-Item -ItemType Directory -Force -Path $inputDir | Out-Null }
$ext = [System.IO.Path]::GetExtension($imagePath)
$imgName = 'b65_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + $ext
Copy-Item -LiteralPath $imagePath -Destination (Join-Path $inputDir $imgName) -Force
Set-Mapped 'image' $imgName

# Make sure the engine is up.
if (-not (Test-B65Port -Port ([int](Get-B65Config -Name video).port))) {
    if ($NoStart) { throw 'ComfyUI is not running (use without -NoStart, or run .\b65.ps1 video start).' }
    Write-B65Log 'Starting ComfyUI for render ...' -Name 'render'
    & (Join-Path $PSScriptRoot 'Video.ps1') -Action start
}

if (-not $SkipValidate) {
    $check = Test-B65Workflow -Workflow $workflow
    if (-not $check.Ok) {
        $msg = "Workflow validation failed:`n  " + ($check.Issues -join "`n  ")
        throw $msg
    }
}

$clientId = [guid]::NewGuid().ToString()
$body = @{ prompt = $workflow; client_id = $clientId }
Write-B65Log ("Submit $Profile render {0}x{1} x {2} frames, {3} steps" -f $w, $h, $f, $st) -Name 'render'
$submit = Invoke-B65Comfy -Path '/prompt' -Method Post -Body $body -TimeoutSec 120
$promptId = [string]$submit.prompt_id
if (-not $promptId) { throw "ComfyUI did not return a prompt_id: $($submit | ConvertTo-Json -Depth 5)" }
Write-B65Log "Queued prompt $promptId" -Name 'render'

$deadline = (Get-Date).AddSeconds($timeout)
$entry = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    try {
        $hist = Invoke-B65Comfy -Path "/history/$promptId" -TimeoutSec 30
    } catch {
        continue
    }
    $prop = $hist.PSObject.Properties[$promptId]
    if ($prop -and $prop.Value.outputs -and @($prop.Value.outputs.PSObject.Properties).Count -gt 0) {
        $entry = $prop.Value
        break
    }
}

if (-not $entry) {
    throw "Render timed out after $timeout s (prompt $promptId). Check the ComfyUI console for OOM."
}

$outRoot = Resolve-B65Path -Path $OutDir
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
if (-not $Name) { $Name = "$Profile-" + (Get-Date -Format 'yyyyMMdd-HHmmss') }

$saved = New-Object System.Collections.Generic.List[string]
$index = 0
foreach ($nodeProp in $entry.outputs.PSObject.Properties) {
    $out = $nodeProp.Value
    foreach ($kind in @('images', 'gifs', 'videos')) {
        $items = $out.$kind
        if (-not $items) { continue }
        foreach ($item in @($items)) {
            $index++
            $suffix = ''
            if (@($items).Count -gt 1) { $suffix = "-$index" }
            $dest = Join-Path $outRoot ($Name + $suffix + [System.IO.Path]::GetExtension($item.filename))
            $url = 'http://127.0.0.1:{0}/view?filename={1}&subfolder={2}&type={3}' -f `
                (Get-B65Config -Name video).port,
                [uri]::EscapeDataString($item.filename),
                [uri]::EscapeDataString([string]$item.subfolder),
                [uri]::EscapeDataString([string]$item.type)
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            $saved.Add($dest)
        }
    }
}

if ($saved.Count -eq 0) { throw "No output files returned for prompt $promptId." }

# Optional 1080p finishing pass.
if ($profileCfg.upscale -and $profileCfg.upscale.enabled -and $profileCfg.upscale.mode -eq 'ffmpeg') {
    $ff = Get-B65Ffmpeg
    if ($ff) {
        $targetHeight = [int]$profileCfg.upscale.height
        foreach ($clip in @($saved)) {
            if ([System.IO.Path]::GetExtension($clip) -notmatch '^\.(mp4|mkv|mov|webm)$') { continue }
            $finalPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($clip),
                ([System.IO.Path]::GetFileNameWithoutExtension($clip) + "_${targetHeight}p.mp4"))
            $vf = "scale=-2:${targetHeight}:flags=lanczos,unsharp=5:5:0.5:5:5:0.0"
            & $ff -y -i $clip -vf $vf -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a copy -movflags +faststart $finalPath
            if ($LASTEXITCODE -eq 0) { $saved.Add($finalPath) }
        }
    } else {
        Write-B65Log 'FFmpeg not found; skipped 1080p upscale.' -Level WARN -Name 'render'
    }
}

$meta = [pscustomobject]@{
    profile = $Profile
    prompt = $Prompt
    negative = $Negative
    width = $w
    height = $h
    frames = $f
    steps = $st
    cfg = $cfgValue
    seed = $seedValue
    workflow = $workflowPath
    comfyPromptId = $promptId
    outputs = $saved
    finishedAt = (Get-Date).ToString('o')
}
Write-B65Json -Path (Join-Path $outRoot ($Name + '.json')) -Value $meta

Write-Host ''
Write-Host 'Render complete:' -ForegroundColor Green
foreach ($s in $saved) { Write-Host "  $s" }
Write-Host ''
