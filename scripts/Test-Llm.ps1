# Test-Llm.ps1 - smoke, quality and speed checks against the running XeStrata API.
[CmdletBinding()]
param(
    [int]$Runs = 1,
    [int]$MaxTokens = 1500,
    [string]$OutDir = 'output\llm-tests'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'B65.psm1') -Force

$status = Get-B65Status
if (-not $status.llm.running) { throw 'LLM is not running. Start it first: .\b65.ps1 llm start' }

$port = [int]$status.llm.port
$key = [string]$status.llm.apiKey
$model = [string]$status.llm.model
$base = 'http://127.0.0.1:{0}' -f $port
$headers = @{ Authorization = "Bearer $key" }

$outPath = Resolve-B65Path -Path $OutDir
New-Item -ItemType Directory -Force -Path $outPath | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Short {
    param([string]$Text, [int]$Len = 90)
    if (-not $Text) { return '' }
    $one = ($Text -replace '\s+', ' ').Trim()
    if ($one.Length -gt $Len) { $one = $one.Substring(0, $Len) }
    return $one
}

function Chat {
    param([string]$Prompt, [int]$Tokens)
    $body = @{
        model       = $model
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $Tokens
        temperature = 0.2
    }
    $json = $body | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $web = Invoke-WebRequest -Uri ($base + '/v1/chat/completions') -Method Post `
            -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300 -UseBasicParsing
        $resp = [System.Text.Encoding]::UTF8.GetString($web.RawContentStream.ToArray()) | ConvertFrom-Json
        $sw.Stop()
        return @{ Ok = $true; Resp = $resp; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return @{ Ok = $false; Resp = $null; Ms = [int]$sw.Elapsed.TotalMilliseconds; Error = $_.Exception.Message }
    }
}

function Text {
    param($Response)
    if (-not $Response) { return '' }
    $msg = $Response.choices[0].message
    if ($msg.content) { return [string]$msg.content }
    return ''
}

function Tps {
    param($Response, [int]$ElapsedMs, [string]$Which)
    if ($Response -and $Response.timings) {
        $v = $Response.timings.$Which
        if ($null -ne $v) { return [math]::Round([double]$v, 1) }
    }
    if ($Which -eq 'predicted_per_second' -and $Response -and $Response.usage.completion_tokens -gt 0 -and $ElapsedMs -gt 0) {
        return [math]::Round($Response.usage.completion_tokens * 1000 / $ElapsedMs, 1)
    }
    return $null
}

function Row {
    param([int]$Run, [string]$Test, [bool]$Ok, [int]$Ms, $Response, [string]$Detail)
    return [pscustomobject]@{
        Run       = $Run
        Test      = $Test
        Ok        = $Ok
        Ms        = $Ms
        PromptTps = (Tps $Response $Ms 'prompt_per_second')
        DecodeTps = (Tps $Response $Ms 'predicted_per_second')
        Detail    = (Short $Detail 90)
    }
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $h = $null
    try { $h = Invoke-RestMethod -Uri ($base + '/health') -TimeoutSec 10 } catch { }
    $sw.Stop()
    $results += Row $run 'health' ([bool]($h -and $h.status -eq 'ok')) ([int]$sw.Elapsed.TotalMilliseconds) $null ('model=' + $(if ($h) { $h.model } else { 'error' }))

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ids = @()
    try { $ids = @((Invoke-RestMethod -Uri ($base + '/v1/models') -Headers $headers -TimeoutSec 15).data | ForEach-Object { $_.id }) } catch { }
    $sw.Stop()
    $results += Row $run 'models' ($ids -contains $model) ([int]$sw.Elapsed.TotalMilliseconds) $null ($ids -join ',')

    $r = Chat '只回答最终答案，不要解释：17 × 23 等于多少？' 600
    $txt = Text $r.Resp
    $results += Row $run 'math' ($txt -match '391') $r.Ms $r.Resp $(if ($r.Ok) { Short $txt } else { $r.Error })

    $r = Chat '用三句话说明 5G RedCap 对物联网模组的价值，并给出一个典型应用场景。' $MaxTokens
    $txt = Text $r.Resp
    $ok = $false
    if ($txt.Trim().Length -gt 20) { $ok = $true }
    $results += Row $run 'chinese' $ok $r.Ms $r.Resp $(if ($r.Ok) { Short $txt } else { $r.Error })

    $r = Chat '只输出一个 JSON 对象，不要 markdown 代码块，不要解释。字段：model=RM500Q，5g=true，redcap=true。' 500
    $txt = Text $r.Resp
    $start = $txt.IndexOf('{')
    $end = $txt.LastIndexOf('}')
    $jsonText = ''
    if ($start -ge 0 -and $end -gt $start) { $jsonText = $txt.Substring($start, $end - $start + 1) }
    $jsonOk = $false
    if ($jsonText) { try { $null = $jsonText | ConvertFrom-Json; $jsonOk = $true } catch { } }
    $results += Row $run 'json' $jsonOk $r.Ms $r.Resp $(if ($r.Ok) { Short $jsonText } else { $r.Error })
}

$results | Format-Table Test, Ok, Ms, PromptTps, DecodeTps, Detail -AutoSize

$avg = @()
foreach ($g in ($results | Where-Object { $_.DecodeTps -ne $null } | Group-Object Test)) {
    $mean = (($g.Group | ForEach-Object { $_.DecodeTps }) | Measure-Object -Average).Average
    $avg += [pscustomobject]@{ Test = $g.Name; AvgDecode = [math]::Round($mean, 1) }
}

$jsonPath = Join-Path $outPath ("llm-test-$stamp.json")
$csvPath = Join-Path $outPath ("llm-test-$stamp.csv")
$mdPath = Join-Path $outPath ("llm-test-$stamp.md")
$payload = @{ testedAt = (Get-Date).ToString('o'); baseURL = $base; model = $model; context = $status.llm.context; runs = $Runs; results = $results; averages = $avg }
$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$md = @()
$md += "# LLM test - $model"
$md += ''
$md += "- Time: $($payload.testedAt)"
$md += "- Base URL: $base"
$md += "- Context: $($status.llm.context)"
$md += "- Runs: $Runs"
$md += ''
$md += '| Run | Test | OK | ms | prompt tok/s | decode tok/s | Detail |'
$md += '|---:|---|---:|---:|---:|---:|---|'
foreach ($row in $results) {
    $md += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $row.Run, $row.Test, $row.Ok, $row.Ms, $row.PromptTps, $row.DecodeTps, (Short $row.Detail 70))
}
$md += ''
$md += '## Averages'
$md += ''
$md += '| Test | decode tok/s |'
$md += '|---|---:|'
foreach ($a in $avg) { $md += ('| {0} | {1} |' -f $a.Test, $a.AvgDecode) }
$md | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host ''
Write-Host ("Saved: {0}" -f $mdPath) -ForegroundColor Green
Write-Host ("       {0}" -f $jsonPath)
Write-Host ("       {0}" -f $csvPath)
