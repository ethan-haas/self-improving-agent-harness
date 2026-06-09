<#
  host-gate-selftest.ps1 - regression suite for the AgentA promotion-gate logic.

  Run AFTER any edit to host/lib/*.ps1 or .claude/ scaffold (esp. meta-improver
  /dgm-improve output) to confirm no safety gate regressed. Read-only: dot-sources
  live host functions and runs the LIVE lossless check.py against throwaway solvers
  in temp dirs. No elevation, no writes to the live tree. ASCII only.

  Exit 0 = all pass; exit 1 = one or more gates regressed.
#>
param([string]$Root = 'C:\Users\<user>\Documents\AgentA\AgentA')
$ErrorActionPreference = 'Stop'
$root = $Root
$pass = 0; $fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { $script:pass++; Write-Host "[PASS] $name" }
    else { $script:fail++; Write-Host "[FAIL] $name :: $detail" }
}
$tmpRoots = @()
function NewTmp { $t = Join-Path $env:TEMP ('gst_'+[guid]::NewGuid().ToString('N').Substring(0,8)); New-Item -ItemType Directory -Force -Path $t | Out-Null; $script:tmpRoots += $t; $t }

# dot-source live gate functions
. (Join-Path $root 'host\lib\Approve-StagedDiff.ps1')   # Test-RewardHackTripwire
. (Join-Path $root 'host\lib\Test-ReviewGate.ps1')
. (Join-Path $root 'host\lib\Detect-Plateau.ps1')

Write-Host "==== A. reward-hack tripwire ===="
$t = NewTmp
foreach ($pat in @('os._exit(0)','sys.settrace','inspect.stack','PYTHONDONTWRITEBYTECODE')) {
    $d = Join-Path $t ("rh_"+[guid]::NewGuid().ToString('N').Substring(0,4)+".patch")
    Set-Content $d "+    $pat" -Encoding ascii
    $r = Test-RewardHackTripwire -Root $root -DiffPath $d
    Check "tripwire catches '$pat'" ($r.Tripped) "not tripped"
}
$d = Join-Path $t 'clean.patch'; Set-Content $d "+    x = sorted(points)" -Encoding ascii
Check "tripwire allows clean diff" (-not (Test-RewardHackTripwire -Root $root -DiffPath $d).Tripped) "false positive"

Write-Host "==== B. review-gate ===="
$c = NewTmp
'{"verdict":"APPROVE"}' | Set-Content (Join-Path $c 'review.json') -Encoding ascii
Check "review-gate APPROVE passes" (Test-ReviewGate -Root $root -CandPath $c -Manifest ([pscustomobject]@{category='experiment'}) -TimeoutMin 1).Pass "did not pass"
'{"verdict":"REJECT"}' | Set-Content (Join-Path $c 'review.json') -Encoding ascii
Check "review-gate REJECT blocks" (-not (Test-ReviewGate -Root $root -CandPath $c -Manifest ([pscustomobject]@{category='experiment'}) -TimeoutMin 1).Pass) "did not block"

Write-Host "==== C. plateau signals (live Detect-Plateau) ===="
function MkGen($r,$g,$task,$metric,[bool]$ext,$ho){ $a=Join-Path $r ("archive\gen-{0:D4}\agent-0001" -f $g); New-Item -ItemType Directory -Force -Path $a|Out-Null
    $m=@{task_id=$task;generation=$g;agent=1}; if($ext){$m.repo_root="workspace/$task"}; $m|ConvertTo-Json|Set-Content (Join-Path $a 'manifest.json') -Encoding ascii
    $s=@{task_id=$task;metric_value=$metric;metric_direction='lower_is_better';holdout_delta=$ho}; if($ext){$s.repo_root="workspace/$task"}; $s|ConvertTo-Json|Set-Content (Join-Path $a 'scores.json') -Encoding ascii }
$r1=NewTmp; New-Item -ItemType Directory -Force -Path (Join-Path $r1 'archive')|Out-Null; foreach($g in 73,74,75,76){MkGen $r1 $g 'lossless' (18500-($g-73)*90) $true 0}
Check "plateau: external diminishing fires" ((Detect-Plateau -Root $r1).Signals.Count -gt 0) "did not fire"
$r2=NewTmp; New-Item -ItemType Directory -Force -Path (Join-Path $r2 'archive')|Out-Null; foreach($g in 73,74,75){MkGen $r2 $g 'tsp' (30000-($g-73)*5000) $true 0}
Check "plateau: external healthy silent" ((Detect-Plateau -Root $r2).Signals.Count -eq 0) "false fire"
$r3=NewTmp; New-Item -ItemType Directory -Force -Path (Join-Path $r3 'archive')|Out-Null; foreach($g in 5,6,7){MkGen $r3 $g 'cov' 0 $false 0.01}
Check "plateau: internal holdout fires" ((Detect-Plateau -Root $r3).Signals.Count -gt 0) "did not fire"

Write-Host "==== D. default-on allowlist (live Test-BenchHashes) ===="
$tb = Get-Content (Join-Path $root 'host\lib\Test-BenchHashes.ps1') -Raw
Check "allowlist present" ($tb.Contains('$selfContained =')) "missing"
Check "allowlist excludes multipattern-match" (-not $tb.Contains("'multipattern-match'")) "still present"
Check "worktree_unsafe opt-out honored" ($tb.Contains('worktree_unsafe')) "missing"
foreach ($task in @('lossless-compress','tsp-multi','nqueens-sum','jobshop-msp','closest-pair-2d','prime-sieve-1e8')) {
    Check "allowlist has $task" ($tb.Contains("'$task'")) "missing"
}

Write-Host "==== E. lossless check.py verifier (live, throwaway solvers) ===="
$lc = Join-Path $root 'workspace\lossless-compress'
if (-not (Test-Path (Join-Path $lc 'check.py'))) {
    Write-Host "[SKIP] no lossless workspace under -Root (sandbox/outer-repo mode); section E not applicable"
} else {
$vt = NewTmp
Copy-Item (Join-Path $lc 'check.py') (Join-Path $vt 'check.py')
$store = @'
import base64, json, sys
def main():
    r=json.loads(sys.stdin.read())
    sys.stdout.write(json.dumps({"data": r["data"]})); return 0
if __name__=="__main__": sys.exit(main())
'@
function RunCheck($solverText){
    [System.IO.File]::WriteAllText((Join-Path $vt 'solver.py'), $solverText, [Text.UTF8Encoding]::new($false))
    Push-Location $vt
    try { $out = & python check.py 2>&1 | Out-String } finally { Pop-Location }
    return $out
}
$o = RunCheck $store
Check "check.py: clean store solver PASSes" ($o -match 'METRIC=\d' -and $o -notmatch 'METRIC=99999999') "out: $($o.Trim())"
$o = RunCheck ("import zlib`n" + $store)
Check "check.py: static 'import zlib' -> reject" ($o -match 'reward-hack' -and $o -match '99999999') "out: $($o.Trim())"
$o = RunCheck ("z = __import__('zlib')`n" + $store)
Check "check.py: __import__('zlib') evasion -> reject" ($o -match 'reward-hack|dynamic import' -and $o -match '99999999') "out: $($o.Trim())"
$o = RunCheck ("import importlib`nz = importlib.import_module('zlib')`n" + $store)
Check "check.py: importlib evasion -> reject" ($o -match 'reward-hack' -and $o -match '99999999') "out: $($o.Trim())"
}

Write-Host "==== F. runner DoS guards (replay) ===="
$rtxt = Get-Content (Join-Path $root 'host\runner.ps1') -Raw
Check "runner does NOT force full replay at boot" (-not ($rtxt -match '\$replayLastCheck\s*=\s*\[DateTime\]::MinValue')) "replayLastCheck=MinValue wedges boot behind a full-archive replay"
$rep = Join-Path $root 'host\lib\Replay-Archive.ps1'
if (Test-Path $rep) {
    $reptxt = Get-Content $rep -Raw
    Check "Replay-Archive verify has a timeout" ($reptxt -match 'WaitForExit\(') "no timeout -> one hung archived verify wedges the runner (DoS)"
} else { Check "Replay-Archive present" $false "missing" }

foreach ($t in $tmpRoots) { Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host ("==== RESULT: {0} passed, {1} failed ====" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }

