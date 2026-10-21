# Build-Video.ps1 - assemble cards, stills and generated clips into a 1080p video.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [switch]$DryRun,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$ff = Get-B65Ffmpeg
if (-not $ff) {
    if ($DryRun) { $ff = 'ffmpeg' } else { throw 'FFmpeg not found. Run .\b65.ps1 setup.' }
}

$manifestPath = Resolve-B65Path -Path $Manifest
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }
$m = Read-B65Json -Path $manifestPath

$W = if ($m.width) { [int]$m.width } else { 1920 }
$H = if ($m.height) { [int]$m.height } else { 1080 }
$FPS = if ($m.fps) { [int]$m.fps } else { 30 }

$buildDir = Join-Path (Get-B65Path 'runtime') 'build'
if (-not (Test-Path -LiteralPath $buildDir)) { New-Item -ItemType Directory -Force -Path $buildDir | Out-Null }

function Invoke-Ffmpeg {
    param([string[]]$FfArgs, [string]$Label)
    if ($DryRun) {
        Write-Host ("[dry-run] " + $ff + ' ' + ($FfArgs -join ' '))
        return
    }
    & $ff @FfArgs
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg failed for $Label ($LASTEXITCODE)" }
}

$sceneFiles = New-Object System.Collections.Generic.List[string]
$index = 0
foreach ($scene in @($m.scenes)) {
    $index++
    $dur = if ($scene.duration) { [double]$scene.duration } else { 5.0 }
    $target = Join-Path $buildDir ("scene-{0:D2}.mp4" -f $index)
    $type = [string]$scene.type

    switch ($type) {
        'card' {
            $cardOut = Join-Path $buildDir ("card-{0:D2}.png" -f $index)
            if ($DryRun) {
                Write-Host ("[dry-run] card {0} -> {1}" -f $scene.data, $cardOut)
            } else {
                & (Join-Path $PSScriptRoot 'New-SpecCard.ps1') -Data $scene.data -Out $cardOut | Out-Null
            }
            $img = $cardOut
            $frames = [int]($dur * $FPS)
            $vf = "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},zoompan=z='min(zoom+0.0005,1.10)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${frames}:s=${W}x${H}:fps=${FPS},setsar=1"
            $a = @('-y', '-loop', '1', '-i', $img, '-t', "$dur", '-vf', $vf,
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-an', $target)
            Invoke-Ffmpeg -FfArgs $a -Label "card $index"
        }
        'image' {
            $img = Resolve-B65Path -Path $scene.path
            if (-not (Test-Path -LiteralPath $img)) {
                if ($DryRun) { Write-Host "[dry-run] missing image: $img" } else { throw "Image not found: $img" }
            }
            $frames = [int]($dur * $FPS)
            if ($scene.effect -eq 'kenburns') {
                $vf = "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},zoompan=z='min(zoom+0.0006,1.15)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${frames}:s=${W}x${H}:fps=${FPS},setsar=1"
            } else {
                $vf = "scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=0x0B1220,setsar=1"
            }
            $a = @('-y', '-loop', '1', '-i', $img, '-t', "$dur", '-vf', $vf,
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-an', $target)
            Invoke-Ffmpeg -FfArgs $a -Label "image $index"
        }
        'clip' {
            $clip = Resolve-B65Path -Path $scene.path
            if (-not (Test-Path -LiteralPath $clip)) {
                if ($DryRun) { Write-Host "[dry-run] missing clip: $clip" } else { throw "Clip not found: $clip" }
            }
            $vf = "scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=0x0B1220,fps=${FPS},setsar=1"
            $a = @('-y', '-i', $clip, '-t', "$dur", '-vf', $vf,
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-an', $target)
            Invoke-Ffmpeg -FfArgs $a -Label "clip $index"
        }
        default { throw "Unknown scene type: $type" }
    }
    $sceneFiles.Add($target)
}

if ($DryRun) {
    Write-Host ("[dry-run] scenes: " + ($sceneFiles -join ', '))
    return
}

$listPath = Join-Path $buildDir 'concat.txt'
$lines = foreach ($f in $sceneFiles) { "file '" + ($f -replace '\\', '/') + "'" }
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($listPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)

$concatOut = Join-Path $buildDir 'concat.mp4'
Invoke-Ffmpeg -FfArgs @('-y', '-f', 'concat', '-safe', '0', '-i', $listPath, '-c', 'copy', $concatOut) -Label 'concat'

$final = if ($Out) { Resolve-B65Path -Path $Out } elseif ($m.output) { Resolve-B65Path -Path $m.output } else { Join-Path (Get-B65Path 'output') 'video.mp4' }
$finalDir = Split-Path -Parent $final
if (-not (Test-Path -LiteralPath $finalDir)) { New-Item -ItemType Directory -Force -Path $finalDir | Out-Null }

$audio = $m.audio
$voice = ''
$music = ''
$vol = 0.12
if ($audio) {
    if ($audio.voice) { $voice = Resolve-B65Path -Path $audio.voice }
    if ($audio.music) { $music = Resolve-B65Path -Path $audio.music }
    if ($null -ne $audio.musicVolume) { $vol = [double]$audio.musicVolume }
}

if ($voice -and (Test-Path -LiteralPath $voice) -and $music -and (Test-Path -LiteralPath $music)) {
    $a = @('-y', '-i', $concatOut, '-i', $voice, '-stream_loop', '-1', '-i', $music,
        '-filter_complex', "[1:a]volume=1.0[v];[2:a]volume=$vol[m];[v][m]amix=inputs=2:duration=first:dropout_transition=2[a]",
        '-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', $final)
    Invoke-Ffmpeg -FfArgs $a -Label 'audio mix'
} elseif ($voice -and (Test-Path -LiteralPath $voice)) {
    $a = @('-y', '-i', $concatOut, '-i', $voice, '-map', '0:v', '-map', '1:a',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', $final)
    Invoke-Ffmpeg -FfArgs $a -Label 'voice'
} elseif ($music -and (Test-Path -LiteralPath $music)) {
    $a = @('-y', '-i', $concatOut, '-stream_loop', '-1', '-i', $music,
        '-filter_complex', "[1:a]volume=$vol[a]", '-map', '0:v', '-map', '[a]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', $final)
    Invoke-Ffmpeg -FfArgs $a -Label 'music'
} else {
    Copy-Item -LiteralPath $concatOut -Destination $final -Force
}

Write-Host ''
Write-Host "Video: $final" -ForegroundColor Green
Write-Host ("Scenes: {0}, {1}x{2} @ {3} fps" -f $index, $W, $H, $FPS)
