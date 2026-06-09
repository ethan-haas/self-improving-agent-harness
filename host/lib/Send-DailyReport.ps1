<#
  Daily report: BurntToast notification + healthchecks.io ping + HTML email.
  Subscription mode: report tokens, not cost_usd.
#>
function Send-DailyReport {
    param([string]$Root, [switch]$DryRun)

    $tokensPath = Join-Path $Root "logs\tokens.jsonl"
    $archive = Join-Path $Root "archive"
    $rejectedDir = Join-Path $archive "rejected"

    $promoted = (Get-ChildItem -Path $archive -Directory -Filter "gen-*" -ErrorAction SilentlyContinue).Count
    $rejected = (Get-ChildItem -Path $rejectedDir -Directory -ErrorAction SilentlyContinue).Count
    $tokens = 0
    if (Test-Path $tokensPath) {
        Get-Content $tokensPath | ForEach-Object {
            try { $j = $_ | ConvertFrom-Json; $tokens += [int]$j.tokens } catch {}
        }
    }

    # Mode-collapse check: pairwise cosine across recent staged diffs
    $cosine = Measure-DiffCosine -Root $Root
    $hackQuarantine = (Get-ChildItem -Path $rejectedDir -Recurse -Filter "rejection.txt" -ErrorAction SilentlyContinue |
        Select-String -Pattern 'reward-hack').Count

    $body = @"
<h2>AgentA Daily Report - $(Get-Date -Format 'yyyy-MM-dd')</h2>
<ul>
<li>Promoted generations: $promoted</li>
<li>Rejected candidates: $rejected</li>
<li>Tokens used (24h): $tokens</li>
<li>Mode-collapse cosine (avg pairwise): $cosine $(if ($cosine -gt 0.85) {'<b style=color:red>ALERT</b>'} else {''})</li>
<li>Reward-hack quarantines (7d): $hackQuarantine</li>
</ul>
"@

    if ($DryRun) {
        Write-Host $body
        return $body
    }

    # BurntToast
    if (Get-Module -ListAvailable -Name BurntToast) {
        Import-Module BurntToast
        New-BurntToastNotification -Text "AgentA daily", "$promoted promoted, $tokens tokens"
    }

    # healthchecks.io
    $localSettings = Join-Path $Root ".claude\settings.local.json"
    if (Test-Path $localSettings) {
        $local = Get-Content $localSettings -Raw | ConvertFrom-Json
        if ($local.env.HEALTHCHECKS_URL) {
            try { Invoke-RestMethod -Uri $local.env.HEALTHCHECKS_URL -Method Post -Body $body -TimeoutSec 10 } catch {}
        }
        if ($local.env.REPORT_EMAIL_TO -and $local.env.SMTP_HOST) {
            Send-MailMessage -To $local.env.REPORT_EMAIL_TO -From $local.env.REPORT_EMAIL_FROM `
                -Subject "AgentA daily $(Get-Date -Format 'yyyy-MM-dd')" -Body $body -BodyAsHtml `
                -SmtpServer $local.env.SMTP_HOST -ErrorAction SilentlyContinue
        }
    }
}

function Measure-DiffCosine {
    param([string]$Root)
    # Coarse proxy: shingled bigram cosine over last 20 promoted diffs
    $diffs = Get-ChildItem (Join-Path $Root "archive") -Recurse -Filter "diff.patch" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20
    if ($diffs.Count -lt 2) { return 0.0 }
    $bags = @()
    foreach ($d in $diffs) {
        $text = Get-Content $d.FullName -Raw
        $words = [regex]::Matches($text, '\w+') | ForEach-Object { $_.Value.ToLower() }
        $bigrams = @{}
        for ($i = 0; $i -lt $words.Count - 1; $i++) {
            $k = "$($words[$i]) $($words[$i+1])"
            if ($bigrams.ContainsKey($k)) { $bigrams[$k]++ } else { $bigrams[$k] = 1 }
        }
        $bags += ,$bigrams
    }
    $sum = 0.0; $n = 0
    for ($i = 0; $i -lt $bags.Count; $i++) {
        for ($j = $i + 1; $j -lt $bags.Count; $j++) {
            $a = $bags[$i]; $b = $bags[$j]
            $dot = 0.0
            foreach ($k in $a.Keys) { if ($b.ContainsKey($k)) { $dot += $a[$k] * $b[$k] } }
            $na = [Math]::Sqrt(($a.Values | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum)
            $nb = [Math]::Sqrt(($b.Values | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum)
            if ($na -gt 0 -and $nb -gt 0) { $sum += $dot / ($na * $nb); $n++ }
        }
    }
    if ($n -gt 0) { return [Math]::Round($sum / $n, 3) } else { return 0.0 }
}
