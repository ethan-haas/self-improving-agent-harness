<#
  Periodic replay drift check.

  For each promoted archive/gen-NNNN/agent-MMMM entry, re-run the manifest's
  verify_command against the archived baseline+diff in a fresh sandbox worktree.
  Compare re-measured metric_value vs archived metric_value. Drift signals
  scorer rot, scorer manipulation post-promotion, or environmental drift.

  Cadence: every 7 days via runner.ps1 poll loop. State file
  agenta\state\replay-drift-state.json tracks last-replay-time + per-entry status
  so we don't re-run entries that succeeded recently (idempotent + cheap).

  Drift thresholds:
    abs(now - then) / then < 0.01           OK
    0.01 .. 0.05                            INFO (log only)
    0.05 .. 0.20                            WARN (log + summary in drift report)
    >= 0.20  OR  ratio doubled/halved        CRITICAL -> write agenta/sentinels/replay-drift-trigger.md
                                                          sentinel so operator notices

  External-repo entries (manifest.repo_root set): re-run verify in the inner
  repo's worktree at the baseline commit + diff applied. Skip if baseline
  commit no longer reachable (inner repo rebased/squashed).
#>
function Replay-Archive {
    param([string]$Root, [int]$MaxEntries = 0)

    $archive = Join-Path $Root "archive"
    if (-not (Test-Path $archive)) { return }

    $stateFile = Join-Path $Root "agenta\state\replay-drift-state.json"
    $state = @{ last_run = $null; entries = @{} }
    if (Test-Path $stateFile) {
        try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch {}
        if (-not $state.entries) { $state.entries = @{} }
    }

    $reportFile = Join-Path $Root ("logs\replay-drift-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
    "[$((Get-Date).ToString('o'))] Replay-Archive start" | Out-File -FilePath $reportFile -Encoding utf8

    $entries = @()
    Get-ChildItem $archive -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^gen-\d+$' } | ForEach-Object {
        $gen = $_
        Get-ChildItem $gen.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $entries += [pscustomobject]@{
                Path = $_.FullName
                Tag = "$($gen.Name)/$($_.Name)"
            }
        }
    }

    if ($MaxEntries -gt 0) { $entries = $entries | Select-Object -Last $MaxEntries }

    $criticalCount = 0
    $warnCount = 0
    $okCount = 0
    $skipCount = 0
    $criticalEntries = @()

    foreach ($e in $entries) {
        $manifestPath = Join-Path $e.Path "manifest.json"
        $scoresPath = Join-Path $e.Path "scores.json"
        if (-not (Test-Path $manifestPath)) { $skipCount++; continue }
        $m = $null
        try { $m = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { $skipCount++; continue }

        $expected = $null
        if ($m.PSObject.Properties.Name -contains 'metric_value') { $expected = [double]$m.metric_value }
        if (-not $expected) { $skipCount++; continue }

        $diffPath = Join-Path $e.Path "diff.patch"
        if (-not (Test-Path $diffPath)) { $skipCount++; continue }

        # Resolve repo for replay
        $repoRoot = $Root
        if ($m.PSObject.Properties.Name -contains 'repo_root' -and $m.repo_root) {
            $cand = [string]$m.repo_root
            if (-not [IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Root $cand }
            if (Test-Path (Join-Path $cand ".git")) { $repoRoot = (Resolve-Path $cand).Path }
        }

        $baseline = [string]$m.baseline_commit
        $verifyCmd = [string]$m.verify_command
        if (-not $baseline -or -not $verifyCmd) { $skipCount++; continue }

        # Spin worktree
        $sbox = Join-Path $env:TEMP ("agenta-replay-" + [guid]::NewGuid().ToString("N"))
        $wtErr = & git -C $repoRoot worktree add --detach $sbox $baseline 2>&1
        if ($LASTEXITCODE -ne 0) {
            "[$($e.Tag)] SKIP worktree-add failed: $($wtErr | Out-String)" | Add-Content $reportFile
            $skipCount++
            continue
        }

        $current = $null
        try {
            $applyErr = & git -C $sbox apply --binary $diffPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                "[$($e.Tag)] SKIP apply-failed: $($applyErr | Out-String)" | Add-Content $reportFile
                $skipCount++
                continue
            }

            # Run verify via git-bash temp script
            $gitBash = $null
            foreach ($p in @('C:\Program Files\Git\bin\bash.exe','C:\Program Files\Git\usr\bin\bash.exe')) {
                if (Test-Path $p) { $gitBash = $p; break }
            }
            if (-not $gitBash) { $skipCount++; continue }

            $tmp = Join-Path $env:TEMP ("agenta-replay-verify-" + [guid]::NewGuid().ToString("N") + ".sh")
            "#!/usr/bin/env bash`nset -e`ncd `"$sbox`"`n$verifyCmd" | Out-File -FilePath $tmp -Encoding utf8
            try {
                $outF = "$tmp.out"; $errF = "$tmp.err"
                $rp = Start-Process -FilePath $gitBash -ArgumentList "`"$tmp`"" -PassThru -NoNewWindow -RedirectStandardOutput $outF -RedirectStandardError $errF
                if ($rp.WaitForExit(90000)) {
                    $vout = (([string](Get-Content $outF -Raw -ErrorAction SilentlyContinue)) + "`n" + ([string](Get-Content $errF -Raw -ErrorAction SilentlyContinue)))
                } else {
                    & taskkill /T /F /PID $rp.Id 2>&1 | Out-Null
                    "[$($e.Tag)] SKIP replay verify timeout >90s (killed)" | Add-Content $reportFile
                    $vout = "REPLAY-TIMEOUT"
                }
                Remove-Item $outF, $errF -ErrorAction SilentlyContinue
            } finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }

            # Parse metric with priority chain:
            #   1. METRIC=<float> line (preferred — every check.py emits this)
            #   2. metric_name: <float> line (yaml-style, e.g. "dev_after_tax_cagr: 0.2031")
            #   3. <metric_name>=<float> if manifest specifies metric_name
            #   4. SKIP (don't guess from last digit — that caused 25 false-positives)
            # Greedy last-digit regex was the bug; pytest summary like "25 passed in 0.05s"
            # would emit "0.05" as the "metric" and trigger CRITICAL drift on every entry.
            $current = $null
            $parseSource = $null
            $voutLines = $vout -split "`n"

            $metricLine = ($voutLines | Where-Object { $_ -match '^METRIC\s*=' } | Select-Object -Last 1)
            if ($metricLine -and ($metricLine -match 'METRIC\s*=\s*([-+]?\d+\.?\d*(?:[eE][-+]?\d+)?)')) {
                $current = [double]$matches[1]
                $parseSource = 'METRIC='
            }

            if ($null -eq $current -and $m.PSObject.Properties.Name -contains 'metric_name' -and $m.metric_name) {
                $mname = [regex]::Escape([string]$m.metric_name)
                $namedLine = ($voutLines | Where-Object { $_ -match "^\s*${mname}\s*[:=]" } | Select-Object -Last 1)
                if ($namedLine -and ($namedLine -match "${mname}\s*[:=]\s*([-+]?\d+\.?\d*(?:[eE][-+]?\d+)?)")) {
                    $current = [double]$matches[1]
                    $parseSource = "${mname}:"
                }
            }

            if ($null -eq $current) {
                "[$($e.Tag)] SKIP no METRIC= or named-metric line found (vout snippet: $($vout.Substring(0,[Math]::Min(200,$vout.Length)) -replace "`r?`n",' | '))" | Add-Content $reportFile
            }
        } finally {
            & git -C $repoRoot worktree remove --force $sbox 2>$null *>$null
            Remove-Item -Recurse -Force $sbox -ErrorAction SilentlyContinue
        }

        if ($null -eq $current) {
            "[$($e.Tag)] SKIP could not parse replayed metric" | Add-Content $reportFile
            $skipCount++
            continue
        }

        $drift = if ($expected -ne 0) { ($current - $expected) / $expected } else { 0.0 }
        $absDrift = [Math]::Abs($drift)

        $status = if ($absDrift -lt 0.01) { 'OK' }
                  elseif ($absDrift -lt 0.05) { 'INFO' }
                  elseif ($absDrift -lt 0.20) { 'WARN' }
                  else { 'CRITICAL' }

        $line = ("[{0}] {1} expected={2:N4} replayed={3:N4} drift={4:P2}" -f $e.Tag, $status, $expected, $current, $drift)
        $line | Add-Content $reportFile

        $state.entries[$e.Tag] = @{ last_replay = (Get-Date).ToString('o'); expected = $expected; replayed = $current; drift = $drift; status = $status }

        switch ($status) {
            'OK'       { $okCount++ }
            'INFO'     { $okCount++ }
            'WARN'     { $warnCount++ }
            'CRITICAL' { $criticalCount++; $criticalEntries += $e.Tag }
        }
    }

    $summary = "Replay-Archive done: $okCount ok, $warnCount warn, $criticalCount critical, $skipCount skipped"
    $summary | Add-Content $reportFile
    Write-RunnerLog -Level "INFO" -Message $summary

    # Sentinel on critical
    if ($criticalCount -gt 0) {
        $trigger = Join-Path $Root "agenta/sentinels/replay-drift-trigger.md"
        if (-not (Test-Path $trigger)) {
            $body = @"
# Replay drift CRITICAL

$criticalCount archived promotions failed replay with >=20% metric drift.

## Critical entries
$(($criticalEntries | ForEach-Object { "- $_" }) -join "`n")

## Suggested action
1. Inspect ``$reportFile`` for per-entry detail.
2. For each critical entry, re-verify the archived diff manually.
3. If drift is from legitimate scorer fix, leave a note in the entry.
4. If drift suggests retroactive scorer manipulation, run /dgm-improve to
   audit + propose scaffold rule preventing future scorer edits on archived
   metrics.

Delete this file (agenta/sentinels/replay-drift-trigger.md) after handling so
future replay-drift checks can fire.
"@
            $body | Out-File -FilePath $trigger -Encoding utf8
            Write-RunnerLog -Level "WARN" -Message "REPLAY-DRIFT: $criticalCount critical -- agenta/sentinels/replay-drift-trigger.md written"
        }
    }

    $state.last_run = (Get-Date).ToString('o')
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $stateFile -Encoding utf8
}
