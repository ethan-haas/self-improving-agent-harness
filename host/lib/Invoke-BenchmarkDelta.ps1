<#
  Tier 5: Benchmark delta. Baseline-aware: applies diff against baseline commit.
#>
function Invoke-BenchmarkDelta {
    param([string]$Root, [string]$DiffPath, [string]$CandPath = "")
    $benchSpec = Join-Path $Root "bench\manifest.json"
    if (-not (Test-Path $benchSpec)) { return @{ Delta = 0.0; Note="no bench configured" } }

    $spec = Get-Content $benchSpec -Raw | ConvertFrom-Json
    $direction = $spec.direction
    $runner = $spec.runner

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

    # Baseline run
    $sboxBase = New-SandboxWorktree -Root $Root -Ref $baseline
    $baselineVal = 0.0
    try {
        Push-Location $sboxBase
        $baselineOut = & cmd /c $runner 2>$null
        $baselineStr = ($baselineOut -join "`n")
        $m = [regex]::Match($baselineStr, '\d+\.\d+')
        if ($m.Success) { $baselineVal = [double]$m.Value }
    } finally {
        Pop-Location
        & git -C $Root worktree remove --force $sboxBase 2>$null *>$null
        Remove-Item -Recurse -Force $sboxBase -ErrorAction SilentlyContinue
    }

    # Candidate run
    $sboxCand = New-SandboxWorktree -Root $Root -Ref $baseline
    $candVal = 0.0
    try {
        Push-Location $sboxCand
        & git apply $DiffPath 2>$null *>$null
        $candOut = & cmd /c $runner 2>$null
        $candStr = ($candOut -join "`n")
        $m2 = [regex]::Match($candStr, '\d+\.\d+')
        if ($m2.Success) { $candVal = [double]$m2.Value }
    } finally {
        Pop-Location
        & git -C $Root worktree remove --force $sboxCand 2>$null *>$null
        Remove-Item -Recurse -Force $sboxCand -ErrorAction SilentlyContinue
    }

    $delta = if ($direction -eq "higher_better") { $candVal - $baselineVal } else { $baselineVal - $candVal }
    return @{ Delta = $delta; Baseline = $baselineVal; Candidate = $candVal; BaselineRef = $baseline }
}
