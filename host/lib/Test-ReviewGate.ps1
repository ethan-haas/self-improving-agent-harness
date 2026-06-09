<#
  Pre-promotion reviewer-verdict gate.

  Race history:
   (1) gen-0001 was PROMOTED before the reviewer subagent finished its audit
       (FSW 3s debounce < reviewer turnaround). Fixed by requiring review.json
       with a terminal verdict before promotion.
   (2) gen-0107 (2026-06-03) was FALSE-REJECTED: the orchestrator runs an
       in-loop review->REWORK->rework->re-review->APPROVE cycle, overwriting
       review.json IN PLACE inside the watched staged dir. The host read the
       intermediate REWORK and rejected terminally, racing the rework. The
       orchestrator's later APPROVE was then orphaned ($processed already had
       the path). Root cause: REWORK was treated as a terminal reject.

  Contract: a staged candidate is promoted only once review.json holds a
  TERMINAL verdict APPROVE. REWORK is NON-TERMINAL (rework in progress) -> wait.
  A transient JSON parse error (file caught mid-overwrite) is also non-terminal
  -> retry. Only APPROVE -> promote, REJECT -> terminal reject.

  Behavior:
    - verdict=APPROVE                 -> Pass (promote)
    - verdict=REJECT                  -> Reject (reviewer says no; terminal)
    - verdict=REWORK / unknown / empty-> NON-TERMINAL, keep polling
    - review.json absent              -> keep polling
    - half-written / parse error      -> NON-TERMINAL, keep polling (retry)
    - no terminal verdict by deadline -> Reject "did not converge"

  Bounded: polls up to TimeoutMin (default 20; rework cycles run ~10-18 min).
  This is a BOUNDED wait (not the unbounded hang that caused the replay-DoS).

  Exception: scaffold-edit candidates skip the gate (different lifecycle;
  /dgm-improve produces them without a reviewer subagent).
#>
function Test-ReviewGate {
    param(
        [string]$Root,
        [string]$CandPath,
        [object]$Manifest,
        [int]$TimeoutMin = 20
    )

    try {
        if ($Manifest -and ($Manifest.category -eq 'scaffold-edit')) {
            return @{ Pass = $true; Reason = "scaffold-edit bypass"; Verdict = "BYPASS" }
        }
    } catch {}

    $reviewPath = Join-Path $CandPath "review.json"
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $lastNonTerminal = "absent"

    while ((Get-Date) -lt $deadline) {
        if (Test-Path $reviewPath) {
            $parsed = $null
            try { $parsed = Get-Content $reviewPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $parsed = $null }
            if ($null -ne $parsed) {
                $verdict = [string]$parsed.verdict
                if ($verdict -eq 'APPROVE') {
                    return @{ Pass = $true; Verdict = $verdict; Reason = "APPROVE" }
                }
                if ($verdict -eq 'REJECT') {
                    return @{ Pass = $false; Verdict = $verdict; Reason = "reviewer verdict: REJECT" }
                }
                # REWORK / unknown / empty -> NON-TERMINAL. The orchestrator overwrites
                # review.json with a terminal verdict when its rework loop converges.
                # Rejecting here races the rework -> false reject + orphan (gen-0107).
                if ([string]::IsNullOrWhiteSpace($verdict)) { $lastNonTerminal = "empty" } else { $lastNonTerminal = $verdict }
            } else {
                # JSON parse failed -> likely caught mid-overwrite. Retry, do not reject.
                $lastNonTerminal = "parse-pending"
            }
        }
        Start-Sleep -Seconds 5
    }

    return @{ Pass = $false; Verdict = "TIMEOUT"; Reason = "reviewer did not converge to APPROVE/REJECT within ${TimeoutMin}min (last: $lastNonTerminal)" }
}
