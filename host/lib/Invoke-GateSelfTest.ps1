<#
  Gate self-test runner (DELTA version). Invoked by runner.ps1 for scaffold-edit
  candidates only: runs host\host-gate-selftest.ps1 against BOTH the baseline and
  baseline+diff sandboxes, and rejects ONLY if the proposed diff INCREASES the
  number of failing checks. This is a regression test, not an absolute-pass test:
  a stale/imperfect baseline (e.g. git HEAD lagging live host patches) is not
  blamed on the edit; only failures the EDIT introduces block promotion.

  The TEST script is the live trusted one under host\ (agent DENY-write); the
  TARGETs are the two sandboxes. Subprocess-isolated; fail-OPEN on compute
  ambiguity (validity is already enforced by tier1-2).
#>
function Invoke-GateSelfTest {
    param([string]$Root, [string]$DiffPath, [object]$Manifest)

    $selftest = Join-Path $Root "host\host-gate-selftest.ps1"
    if (-not (Test-Path $selftest)) {
        return @{ Pass = $true; Reason = "selftest absent (skipped)" }
    }
    $baseline = "HEAD"
    try { if ($Manifest -and $Manifest.baseline_commit) { $baseline = [string]$Manifest.baseline_commit } } catch {}

    function _failcount([bool]$applyDiff) {
        $sbox = New-SandboxWorktree -Root $Root -Ref $baseline
        if (-not $sbox -or -not (Test-Path $sbox)) { return $null }
        try {
            if ($applyDiff) {
                Push-Location $sbox
                & git apply $DiffPath 2>&1 | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
                Pop-Location
                if (-not $ok) { return @{ apply = $false } }
            }
            $outFile = Join-Path $env:TEMP ("gst-" + [guid]::NewGuid().ToString("N") + ".out")
            & powershell -NoProfile -ExecutionPolicy Bypass -File $selftest -Root $sbox *> $outFile
            $txt = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
            Remove-Item $outFile -ErrorAction SilentlyContinue
            if (-not $txt) { return $null }
            $m = [regex]::Match($txt, 'RESULT:\s*\d+\s*passed,\s*(\d+)\s*failed')
            if (-not $m.Success) { return $null }
            return @{ apply = $true; fails = [int]$m.Groups[1].Value }
        } finally {
            try { Pop-Location } catch {}
            & git -C $Root worktree remove --force $sbox 2>&1 | Out-Null
            Remove-Item -Recurse -Force $sbox -ErrorAction SilentlyContinue
        }
    }

    $base = _failcount $false
    $cand = _failcount $true

    if ($null -eq $cand) { return @{ Pass = $true; Reason = "candidate selftest not computable (skip)" } }
    if ($cand.ContainsKey('apply') -and -not $cand.apply) {
        return @{ Pass = $false; Reason = "scaffold diff did not apply in sandbox" }
    }
    if ($null -eq $base) { return @{ Pass = $true; Reason = "baseline selftest not computable (skip; cand fails=$($cand.fails))" } }

    if ($cand.fails -gt $base.fails) {
        return @{ Pass = $false; Reason = "scaffold edit ADDED gate failures: baseline=$($base.fails) -> candidate=$($cand.fails)" }
    }
    return @{ Pass = $true; Reason = "no new gate failures (baseline=$($base.fails), candidate=$($cand.fails))" }
}
