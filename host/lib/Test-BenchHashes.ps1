<#
  Tier 1-2: Parse + Unit
  Reads baseline_commit from manifest, spins up a worktree at that ref, applies
  diff there, runs parse + tests. Captures stderr from git failures and surfaces
  it in the rejection reason (was previously swallowed by 2>$null).
#>
function Test-BenchHashes {
    param([string]$Root, [string]$DiffPath, [string]$CandPath = "")

    $baseline = ""
    $repoRoot = $Root   # default = AgentA root
    if ($CandPath) {
        $manifestPath = Join-Path $CandPath "manifest.json"
        if (Test-Path $manifestPath) {
            try {
                $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                if ($manifest.baseline_commit) { $baseline = $manifest.baseline_commit }
                if ($manifest.PSObject.Properties.Name -contains 'repo_root' -and $manifest.repo_root) {
                    $candidate = [string]$manifest.repo_root
                    # Allow relative (resolved from AgentA root) or absolute
                    if (-not [IO.Path]::IsPathRooted($candidate)) {
                        $candidate = Join-Path $Root $candidate
                    }
                    if (Test-Path (Join-Path $candidate ".git")) {
                        $repoRoot = (Resolve-Path $candidate).Path
                    }
                }
            } catch {}
        }
        $blPath = Join-Path $CandPath "baseline.txt"
        if (-not $baseline -and (Test-Path $blPath)) {
            $baseline = (Get-Content $blPath -Raw).Trim()
        }
    }
    if (-not $baseline) { $baseline = "HEAD" }

    # Pre-flight: manifest completeness gate (cheap, before spinning a worktree)
    if ($CandPath) {
        $manifestPath = Join-Path $CandPath "manifest.json"
        if (-not (Test-Path $manifestPath)) {
            return @{ Pass=$false; Reason="manifest.json missing" }
        }
        try {
            $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        } catch {
            return @{ Pass=$false; Reason="manifest.json not valid JSON: $_" }
        }
        $required = @('task_id','baseline_commit','verify_command','metric_name','metric_value','tests_passed','tests_total','verify_exit_code')
        foreach ($k in $required) {
            if (-not ($m.PSObject.Properties.Name -contains $k)) {
                return @{ Pass=$false; Reason="manifest missing required field '$k'" }
            }
        }
        if ([int]$m.verify_exit_code -ne 0) {
            return @{ Pass=$false; Reason="manifest reports verify_exit_code=$($m.verify_exit_code); agent staged a failing run" }
        }
        # Accept manifest if failing count <= explicitly-declared known failures.
        # Default known_failures=0 means strict (all must pass).
        $known = 0
        try {
            if ($m.PSObject.Properties.Name -contains 'tests_known_failures') {
                $known = [int]$m.tests_known_failures
            }
        } catch {}
        $failing = [int]$m.tests_total - [int]$m.tests_passed
        if ($failing -gt $known) {
            return @{ Pass=$false; Reason="$failing failing tests > $known declared known_failures (manifest: $($m.tests_passed)/$($m.tests_total))" }
        }
        if ($known -gt 0) {
            if (-not ($m.PSObject.Properties.Name -contains 'tests_note')) {
                return @{ Pass=$false; Reason="tests_known_failures=$known requires manifest.tests_note explaining the failures" }
            }
        }

        # Tier-0 ORACLE-GAMING detector: reject if diff touches the scorer/metric script
        # AND metric jumped >= 2x baseline. Real incident: gen-0027/agent-0002 modified
        # scripts/structural_fidelity_suite.py to loosen tolerances, composite 25.27->63.74,
        # engine unchanged. Post-hoc reviewer caught + reset --hard but host already promoted.
        try {
            $diffText = Get-Content $DiffPath -Raw -ErrorAction SilentlyContinue
            if ($diffText) {
                $scorerHit = $false
                # File-header lines: +++ b/<path>. Scorer scripts are anything matching score|metric|bench|fidelity in path basename.
                foreach ($l in ($diffText -split "`n")) {
                    if ($l -match '^\+\+\+ b/(.+)$') {
                        $p = $matches[1].ToLower()
                        if ($p -match '(^|/)(score|metric|bench|fidelity|verify|grade|eval)[^/]*\.(py|ps1|sh|js|ts)$' -or `
                            $p -match '(^|/)scripts/.*(score|metric|fidelity|grade)' -or `
                            $p -match '(^|/)(scoring|metrics|benchmarks|grading|eval)/') {
                            $scorerHit = $true
                            break
                        }
                    }
                }
                if ($scorerHit) {
                    $mb = $null
                    foreach ($k in @('metric_before','metric_value_before','baseline_metric')) {
                        if ($m.PSObject.Properties.Name -contains $k) { $mb = [double]$m.$k; break }
                    }
                    $mv = [double]$m.metric_value
                    if ($mb -ne $null -and $mb -gt 0) {
                        $jump = $mv / $mb
                        if ($jump -ge 2.0) {
                            return @{ Pass=$false; Reason="ORACLE-GAMING: diff touches scorer/metric script AND metric jumped $('{0:N2}' -f $jump)x baseline ($mb -> $mv). Suspected metric inflation via tolerance loosening. If genuine, document scorer fix in agenta\infra\outcomes/<task>-meta.md and route to meta-improver." }
                        }
                    }
                }
            }
        } catch {}

        # Cross-check manifest.tests_total against verify.log's actual pytest count.
        # Catches the coder's recurring "task counts mistaken for pytest counts" drift
        # (e.g. manifest claimed 370/400 when verify.log showed 442 passed, 6 failed).
        $verifyLogPath = Join-Path $CandPath "verify.log"
        if (Test-Path $verifyLogPath) {
            $vlog = Get-Content $verifyLogPath -Raw -ErrorAction SilentlyContinue
            if ($vlog) {
                # Look for pytest summary like "N passed, M failed" (any order, any extras)
                $passMatch = [regex]::Match($vlog, '(\d+)\s+passed')
                $failMatch = [regex]::Match($vlog, '(\d+)\s+failed')
                if ($passMatch.Success) {
                    $logPass = [int]$passMatch.Groups[1].Value
                    $logFail = if ($failMatch.Success) { [int]$failMatch.Groups[1].Value } else { 0 }
                    $logTotal = $logPass + $logFail
                    # Allow 5% drift to absorb skipped/xfail noise
                    $drift = [Math]::Abs($logTotal - [int]$m.tests_total)
                    $threshold = [Math]::Max(5, [int]([int]$m.tests_total * 0.05))
                    if ($drift -gt $threshold) {
                        return @{ Pass=$false; Reason="manifest tests_total=$($m.tests_total) but verify.log shows $logPass passed + $logFail failed = $logTotal (drift $drift > threshold $threshold). Check pytest counts vs task-submission counts." }
                    }
                }
            }
        }
        # verify.log presence is required so we can audit
        $verifyLog = Join-Path $CandPath "verify.log"
        if (-not (Test-Path $verifyLog)) {
            return @{ Pass=$false; Reason="verify.log missing -- agent did not capture its verify run" }
        }
    }

    $sbox = New-SandboxWorktree -Root $repoRoot -Ref $baseline
    if (-not $sbox -or -not (Test-Path $sbox)) {
        return @{ Pass=$false; Reason="worktree add failed for baseline $baseline in repo $repoRoot" }
    }
    try {
        Push-Location $sbox
        # Capture stderr so safe.directory / other git failures are visible
        $checkErr = & git apply --check $DiffPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = ($checkErr | Out-String).Trim() -replace "`r?`n",' | '
            return @{ Pass=$false; Reason="git apply --check failed (baseline=$baseline): $msg" }
        }
        $applyErr = & git apply $DiffPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = ($applyErr | Out-String).Trim() -replace "`r?`n",' | '
            return @{ Pass=$false; Reason="git apply failed (baseline=$baseline): $msg" }
        }

        # bench manifest hash check
        $benchMan = Join-Path $Root "bench\manifest.sha256"
        if (Test-Path $benchMan) {
            $expected = (Get-Content $benchMan) -split "`n"
            foreach ($line in $expected) {
                if ($line -match '^([0-9a-f]+)\s+(.+)$') {
                    $hash = $matches[1]; $rel = $matches[2]
                    $actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $sbox $rel)).Hash.ToLower()
                    if ($actual -ne $hash) { return @{ Pass=$false; Reason="bench tampered: $rel" } }
                }
            }
        }

        # Tier 1: parse all .py
        $py = Get-ChildItem -Recurse -Filter *.py -ErrorAction SilentlyContinue
        foreach ($f in $py) {
            $parseErr = & python -m py_compile $f.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = ($parseErr | Out-String).Trim() -replace "`r?`n",' | '
                return @{ Pass=$false; Reason="parse error $($f.Name): $msg" }
            }
        }

        # Tier 2: unit. Prefer manifest's verify_command (task-scoped); fall back to
        # auto-detect (which is fragile across multiple tasks in the same repo).
        $verifyCmd = $null
        if ($CandPath) {
            $manifestPath = Join-Path $CandPath "manifest.json"
            if (Test-Path $manifestPath) {
                try {
                    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                    if ($manifest.verify_command) { $verifyCmd = [string]$manifest.verify_command }
                } catch {}
            }
        }

        # For external-repo (manifest.repo_root set), skip re-running verify in the sandbox.
        # The sandbox worktree at baseline_commit doesn't include uncommitted-but-present
        # working-tree artifacts (e.g. locally-generated .onnx model files for tests that
        # the agent's live verify run saw), causing environmental false failures that
        # don't reflect real regression. Trust the agent's verify.log (cross-checked
        # against manifest in the tier-0 gate above) + the tier-7 critic on the diff.
        $isExternalRepo = $false
        if ($CandPath) {
            $manifestPath = Join-Path $CandPath "manifest.json"
            if (Test-Path $manifestPath) {
                try {
                    $mEx = Get-Content $manifestPath -Raw | ConvertFrom-Json
                    if ($mEx.PSObject.Properties.Name -contains 'repo_root' -and $mEx.repo_root) {
                        $isExternalRepo = $true
                    }
                } catch {}
            }
        }
        $worktreeSafe = $false
        # Default-on independent verification for external-repo tasks: verify in
        # the worktree if the task opts in (worktree_safe) OR is a known self-contained
        # task (generates its own inputs; allowlist from the 2026-05-30 audit).
        # worktree_unsafe forces it off for artifact-dependent tasks.
        try {
            if ($isExternalRepo) {
                $tid = [string]$mEx.task_id
                $selfContained = @('closest-pair-2d','jobshop-msp','lossless-compress','nqueens-sum','prime-sieve-1e8','tsp-multi')
                $optIn  = ($mEx.PSObject.Properties.Name -contains 'worktree_safe') -and $mEx.worktree_safe
                $optOut = ($mEx.PSObject.Properties.Name -contains 'worktree_unsafe') -and $mEx.worktree_unsafe
                if ((-not $optOut) -and ($optIn -or ($selfContained -contains $tid))) { $worktreeSafe = $true }
            }
        } catch {}
        if ($isExternalRepo -and -not $worktreeSafe) {
            # Skip Tier 2 re-verify
        } elseif ($verifyCmd) {
            # Use Git Bash (NOT WSL bash, which refuses SYSTEM context). Pass via temp .sh
            # to avoid PowerShell->bash quoting corruption.
            $gitBash = $null
            foreach ($p in @(
                'C:\Program Files\Git\bin\bash.exe',
                'C:\Program Files\Git\usr\bin\bash.exe',
                'C:\Program Files (x86)\Git\bin\bash.exe'
            )) {
                if (Test-Path $p) { $gitBash = $p; break }
            }
            if ($gitBash) {
                $tmpScript = Join-Path $env:TEMP ("agenta-verify-" + [guid]::NewGuid().ToString("N") + ".sh")
                $body = "#!/usr/bin/env bash`nset -e`n" + $verifyCmd
                [System.IO.File]::WriteAllText($tmpScript, $body, [Text.UTF8Encoding]::new($false))
                try {
                    $testErr = & $gitBash $tmpScript 2>&1
                } finally {
                    Remove-Item $tmpScript -ErrorAction SilentlyContinue
                }
            } else {
                $testErr = & cmd /c $verifyCmd 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                $msg = ($testErr | Out-String).Trim() -replace "`r?`n",' | '
                $tail = if ($msg.Length -gt 500) { $msg.Substring($msg.Length - 500) } else { $msg }
                return @{ Pass=$false; Reason="verify_command failed: ...$tail" }
            }
        } elseif (Test-Path "package.json") {
            $testErr = & npm test --silent 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = ($testErr | Out-String).Trim() -replace "`r?`n",' | '
                return @{ Pass=$false; Reason="npm test failed: $msg" }
            }
        } elseif ((Test-Path "pytest.ini") -or (Test-Path "pyproject.toml") -or (Get-ChildItem -Recurse -Filter test_*.py -ErrorAction SilentlyContinue)) {
            $testErr = & pytest -q --import-mode=importlib 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = ($testErr | Out-String).Trim() -replace "`r?`n",' | '
                $tail = if ($msg.Length -gt 400) { $msg.Substring($msg.Length - 400) } else { $msg }
                return @{ Pass=$false; Reason="pytest failed: ...$tail" }
            }
        }

        return @{ Pass=$true; Baseline=$baseline }
    } finally {
        Pop-Location
        & git -C $repoRoot worktree remove --force $sbox 2>$null *>$null
        Remove-Item -Recurse -Force $sbox -ErrorAction SilentlyContinue
    }
}

function New-SandboxWorktree {
    param([string]$Root, [string]$Ref = "HEAD")
    $tmp = Join-Path $env:TEMP ("agenta-sbox-" + [guid]::NewGuid().ToString("N"))
    $err = & git -C $Root worktree add --detach $tmp $Ref 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Try to log to runner log so future runs surface this
        $logFile = Join-Path $Root "logs\runner.log"
        $msg = "[$((Get-Date).ToString('o'))] [ERROR] worktree add failed (ref=$Ref): $(($err|Out-String).Trim() -replace ""`r?`n"",' | ')"
        try { Add-Content -Path $logFile -Value $msg -Encoding utf8 } catch {}
        return $null
    }
    return $tmp
}
