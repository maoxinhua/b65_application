# New-SpecCard.ps1 - render a 1920x1080 HTML spec card to PNG with Edge headless.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Data,
    [string]$Out = '',
    [string]$Template = 'assets\cards\spec-card.html'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

$dataPath = Resolve-B65Path -Path $Data
if (-not (Test-Path -LiteralPath $dataPath)) { throw "Card data not found: $dataPath" }
$card = Read-B65Json -Path $dataPath

$templatePath = Resolve-B65Path -Path $Template
if (-not (Test-Path -LiteralPath $templatePath)) { throw "Template not found: $templatePath" }
$html = [System.IO.File]::ReadAllText($templatePath)

$bullets = ''
foreach ($b in @($card.bullets)) {
    if ($b) { $bullets += '<li>' + (ConvertTo-HtmlText ([string]$b)) + '</li>' }
}
$specs = ''
foreach ($s in @($card.specs)) {
    if (-not $s) { continue }
    $specs += '<div class="spec"><div class="k">' + (ConvertTo-HtmlText ([string]$s.k)) +
        '</div><div class="v">' + (ConvertTo-HtmlText ([string]$s.v)) + '</div></div>'
}

$logoHtml = ''
if ($card.logo) {
    $logoPath = Resolve-B65Path -Path ([string]$card.logo)
    if (Test-Path -LiteralPath $logoPath) {
        $logoUri = ([uri]$logoPath).AbsoluteUri
        $logoHtml = '<img class="logo" src="' + $logoUri + '" alt="logo" />'
    }
}

$bgStyle = 'background: radial-gradient(1200px 700px at 78% 18%, #12324a 0%, #0b1220 55%, #070b12 100%);'
if ($card.background) {
    $bgPath = Resolve-B65Path -Path ([string]$card.background)
    if (Test-Path -LiteralPath $bgPath) {
        $bgUri = ([uri]$bgPath).AbsoluteUri
        $bgStyle = "background-image: linear-gradient(90deg, #070b12 0%, rgba(7,11,18,0.72) 45%, rgba(7,11,18,0.25) 100%), url('$bgUri'); background-size: cover; background-position: center;"
    }
}

$accent = '#00A3E0'
if ($card.accent) { $accent = [string]$card.accent }

$html = $html.Replace('{{TITLE}}', (ConvertTo-HtmlText ([string]$card.title)))
$html = $html.Replace('{{SUBTITLE}}', (ConvertTo-HtmlText ([string]$card.subtitle)))
$html = $html.Replace('{{KICKER}}', (ConvertTo-HtmlText ([string]$card.kicker)))
$html = $html.Replace('{{FOOTER}}', (ConvertTo-HtmlText ([string]$card.footer)))
$html = $html.Replace('{{BULLETS}}', $bullets)
$html = $html.Replace('{{SPECS}}', $specs)
$html = $html.Replace('{{ACCENT}}', $accent)
$html = $html.Replace('{{BG_STYLE}}', $bgStyle)
$html = $html.Replace('{{LOGO_IMG}}', $logoHtml)

$name = [System.IO.Path]::GetFileNameWithoutExtension($dataPath)
$htmlPath = Join-Path (Join-Path (Get-B65Path 'runtime') 'cards') ($name + '.html')
$dir = Split-Path -Parent $htmlPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($htmlPath, $html, $utf8)

if (-not $Out) {
    if ($card.output) { $Out = [string]$card.output } else { $Out = "output\cards\$name.png" }
}
$outPath = Resolve-B65Path -Path $Out
$outDir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$edge = Get-B65Edge
if (-not $edge) { throw 'Microsoft Edge not found; install Edge to render cards.' }

$uri = ([uri]$htmlPath).AbsoluteUri
Write-B65Log "Rendering card $uri -> $outPath" -Name 'card'
& $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
    --window-size=1920,1080 --virtual-time-budget=3000 --screenshot="$outPath" $uri | Out-Null

if (-not (Test-Path -LiteralPath $outPath)) { throw "Edge did not produce $outPath" }
Write-Host "Card: $outPath" -ForegroundColor Green
