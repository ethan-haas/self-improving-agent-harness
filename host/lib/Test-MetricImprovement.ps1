<#
  Metric-improvement gate for EXTERNAL-REPO tasks (closes the regression gap:
  tier5/6 +0.02 holdout is skipped for external tasks, so a valid-but-worse
  candidate would otherwise promote).

  Host-computes the metric at baseline and at baseline+diff (two worktrees, runs
  check.py, parses METRIC=). Rejects only on a CONFIDENT regression; fail-OPEN
  (skip) on any compute/parse ambiguity so legit work is never false-rejected
  (validity is already guaranteed by default-on verify). Internal tasks (no
  repo_root) keep the +0.02 holdout and are skipped here.

  The candidate metric is HOST-computed, so the agent cannot spoof it.

  Long-horizon cap (2026-06-03): if the manifest sets max_metric_gain_per_gen,
  the gate ALSO rejects candidates that improve by MORE than that cap. This forces
  accumulation tasks to climb in bounded per-generation increments (committing
  state each gen) instead of leaping the whole ladder in one generation -> stresses
  the multi-generation commit-chain + plateau machinery that single-shot optimizer
  tasks (maxcut/pow-canary saturated in 1-3 gens) never exercise. Opt-in: tasks
  without the key are unaffected.
#>
function Test-MetricImprovement {
    param([string]$Root, [string]$DiffPath, [object]$Manifest)

    if (-not ($Manifest -and $Manifest.repo_root)) { return @{ Pass = $true; Reason = "internal task (skip; +0.02 holdout applies)" } }
    $repoRoot = [string]$Manifest.repo_root
    if (-not [IO.Path]::IsPathRooted($repoRoot)) { $repoRoot = Join-Path $Root $repoRoot }
    if (-not (Test-Path (Join-Path $repoRoot ".git"))) { return @{ Pass = $true; Reason = "repo_root not a git repo (skip)" } }
    $baseline = if ($Manifest.baseline_commit) { [string]$Manifest.baseline_commit } else { "HEAD" }
    $dir = if ($Manifest.metric_direction) { [string]$Manifest.metric_direction } else { "lower_is_better" }

    function _metric([string]$sbox, [bool]$applyDiff) {
        if ($applyDiff) {
            Push-Location $sbox; & git apply $DiffPath 2>&1 | Out-Null; $ok = ($LASTEXITCODE -eq 0); Pop-Location
            if (-not $ok) { return $null }
        }
        if (-not (Test-Path (Join-Path $sbox "check.py"))) { return $null }
        Push-Location $sbox
        try { $out = & python -S check.py 2>&1 | Out-String } finally { Pop-Location }
        $m = [regex]::Matches($out, 'METRIC=([0-9.eE+-]+)')
        if ($m.Count -eq 0) { return $null }
        $v = 0.0
        if (-not [double]::TryParse($m[$m.Count - 1].Groups[1].Value, [ref]$v)) { return $null }
        return $v
    }

    $base = $null
    $sb1 = New-SandboxWorktree -Root $repoRoot -Ref $baseline
    if ($sb1) { try { $base = _metric $sb1 $false } finally { & git -C $repoRoot worktree remove --force $sb1 2>&1 | Out-Null; Remove-Item -Recurse -Force $sb1 -ErrorAction SilentlyContinue } }

    $cand = $null
    $sb2 = New-SandboxWorktree -Root $repoRoot -Ref $baseline
    if ($sb2) { try { $cand = _metric $sb2 $true } finally { & git -C $repoRoot worktree remove --force $sb2 2>&1 | Out-Null; Remove-Item -Recurse -Force $sb2 -ErrorAction SilentlyContinue } }

    if ($null -eq $base -or $null -eq $cand) { return @{ Pass = $true; Reason = "metric not computable (skip; base=$base cand=$cand)" } }

    # treat the FAIL sentinel (99999999) as non-comparable -> let earlier tiers handle it
    if ($cand -ge 99999999 -or $base -ge 99999999) { return @{ Pass = $true; Reason = "sentinel metric (skip; base=$base cand=$cand)" } }

    $improved = if ($dir -eq 'higher_is_better') { $cand -gt $base } else { $cand -lt $base }
    if (-not $improved) { return @{ Pass = $false; Reason = "metric regression: candidate=$cand vs baseline=$base ($dir)" } }

    # Optional per-generation advance cap -> forces incremental long-horizon climbs.
    # A task that sets max_metric_gain_per_gen cannot leap the whole ladder in one gen;
    # it must commit bounded increments across many generations.
    if ($Manifest.PSObject.Properties.Name -contains 'max_metric_gain_per_gen' -and $null -ne $Manifest.max_metric_gain_per_gen) {
        $cap = 0.0
        if ([double]::TryParse([string]$Manifest.max_metric_gain_per_gen, [ref]$cap) -and $cap -gt 0) {
            $gain = [math]::Abs($cand - $base)
            if ($gain -gt $cap) {
                return @{ Pass = $false; Reason = "per-gen gain $gain exceeds cap $cap (commit smaller increments): base=$base cand=$cand ($dir)" }
            }
        }
    }

    return @{ Pass = $true; Reason = "improved: $base -> $cand ($dir)" }
}
