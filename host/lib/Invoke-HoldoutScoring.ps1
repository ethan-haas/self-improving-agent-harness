<#
  Tier 6: Sealed holdout - reads from holdout/ folder which has DENY-read ACL for the
  agent user. Only SYSTEM (host runner Task Scheduler context) can read score.py.
  Baseline-aware: applies diff against baseline commit, not HEAD.
#>
function Invoke-HoldoutScoring {
    param([string]$Root, [string]$DiffPath, [string]$CandPath = "")

    $holdoutDir = Join-Path $Root "holdout"
    $scorePy = Join-Path $holdoutDir "score.py"
    if (-not (Test-Path $scorePy)) {
        return @{ Delta = 0.0; Note = "holdout/score.py not present - passthrough (configure before production)" }
    }

    # Resolve baseline
    $baseline = "HEAD"
    if ($CandPath) {
        $manifestPath = Join-Path $CandPath "manifest.json"
        if (Test-Path $manifestPath) {
            try {
                $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                if ($manifest.baseline_commit) { $baseline = $manifest.baseline_commit }
            } catch {}
        }
    }

    # Baseline score: from a worktree at baseline
    $sboxBase = New-SandboxWorktree -Root $Root -Ref $baseline
    $baselineScore = 0.0
    try {
        $baselineOut = & python $scorePy $sboxBase 2>$null | Select-Object -Last 1
        $baselineScore = [double]($baselineOut -as [string])
    } finally {
        & git -C $Root worktree remove --force $sboxBase 2>$null *>$null
        Remove-Item -Recurse -Force $sboxBase -ErrorAction SilentlyContinue
    }

    # Candidate score: from a worktree at baseline + diff applied
    $sboxCand = New-SandboxWorktree -Root $Root -Ref $baseline
    $candScore = 0.0
    try {
        Push-Location $sboxCand
        & git apply $DiffPath 2>$null *>$null
        $candOut = & python $scorePy $sboxCand 2>$null | Select-Object -Last 1
        $candScore = [double]($candOut -as [string])
    } finally {
        Pop-Location
        & git -C $Root worktree remove --force $sboxCand 2>$null *>$null
        Remove-Item -Recurse -Force $sboxCand -ErrorAction SilentlyContinue
    }

    return @{ Delta = ($candScore - $baselineScore); Baseline = $baselineScore; Candidate = $candScore; BaselineRef = $baseline }
}
