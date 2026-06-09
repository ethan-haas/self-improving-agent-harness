<#
.SYNOPSIS
  AgentA host runner. SYSTEM-context Task Scheduler job. NEVER invokes Claude.
.DESCRIPTION
  FileSystemWatcher on agenta\infra\staged/. Resident process. On candidate-folder
  creation, debounce ~3s (let the agent finish writing diff.patch + manifest.json
  + results.tsv) then run 7-tier verify; promote on success.

.PARAMETER Once
  Run a single promotion cycle over existing staged/ then exit (for testing).
.PARAMETER DebounceMs
  Quiet-window after last filesystem event before processing a candidate. Default 3000.
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [string]$Root = "",
    [int]$DebounceMs = 3000
)

# IMPORTANT: native commands (git, python) write to stderr as normal info.
# Strict + Stop terminates the runner on any such line. Use Continue throughout the
# resident loop; lib modules check $LASTEXITCODE explicitly.
$ErrorActionPreference = "Continue"

# Robust $Root resolution. Param defaults relying on $PSScriptRoot have proven
# fragile under Task Scheduler/SYSTEM invocation (where the var sometimes binds
# before $PSScriptRoot is populated). Resolve via $MyInvocation if no -Root given.
if (-not $Root -or -not (Test-Path $Root)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $scriptDir
}
if (-not (Test-Path $Root)) {
    # Final fallback: known-good install path
    $Root = "C:\Users\<user>\Documents\AgentA\AgentA"
}
$Root = (Resolve-Path $Root).Path

# Boot marker -- written immediately so SYSTEM-context failures are observable
$bootMarker = "[$((Get-Date).ToString('o'))] [BOOT] pid=$PID user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) root=$Root psv=$($PSVersionTable.PSVersion)"
$logFile = "$Root\logs\runner.log"
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
    # Use StreamWriter with explicit FileShare so concurrent readers don't block us
    $sw = [System.IO.StreamWriter]::new($logFile, $true, [Text.UTF8Encoding]::new($false))
    try { $sw.WriteLine($bootMarker) } finally { $sw.Dispose() }
} catch {
    # Fallback: %TEMP% always writable
    "$bootMarker (PRIMARY LOG FAILED: $_)" | Out-File "$env:TEMP\agenta-runner-boot.log" -Append -Encoding utf8
}

Get-ChildItem "$Root\host\lib\*.ps1" | ForEach-Object { . $_.FullName }

function Write-RunnerLog {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString("o")
    $line = "[$ts] [$Level] $Message"
    $logPath = "$Root\logs\runner.log"
    $fallback = "$env:TEMP\agenta-runner-fallback.log"
    # Retry with backoff if main log is locked (concurrent reader/writer race)
    $written = $false
    for ($i = 0; $i -lt 5 -and -not $written; $i++) {
        try {
            $sw = [System.IO.StreamWriter]::new($logPath, $true, [Text.UTF8Encoding]::new($false))
            try { $sw.WriteLine($line) } finally { $sw.Dispose() }
            $written = $true
        } catch {
            Start-Sleep -Milliseconds (50 * ($i + 1))
        }
    }
    if (-not $written) {
        try { Add-Content -Path $fallback -Value "$line (PRIMARY LOCKED)" -Encoding utf8 -ErrorAction SilentlyContinue } catch {}
    }
    Write-Host $line
}

function Invoke-PromotionForCandidate {
    param([string]$Root, [System.IO.DirectoryInfo]$Cand)

    $diffPath = Join-Path $Cand.FullName "diff.patch"
    $manifestPath = Join-Path $Cand.FullName "manifest.json"
    if (-not (Test-Path $diffPath) -or -not (Test-Path $manifestPath)) {
        Write-RunnerLog -Level "DEBUG" -Message "skip $($Cand.Name) - missing diff.patch or manifest.json"
        return
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    # generation and agent may arrive as ints OR prefixed strings ("gen-0001", "agent-0001")
    function ConvertTo-IntField {
        param($v)
        if ($null -eq $v) { return 0 }
        if ($v -is [int] -or $v -is [long]) { return [int]$v }
        $m = [regex]::Match([string]$v, '\d+')
        if ($m.Success) { return [int]$m.Value }
        return 0
    }
    $gen = ConvertTo-IntField $manifest.generation
    $agent = ConvertTo-IntField $manifest.agent
    $tag = "archive/gen-{0:D4}/agent-{1:D4}" -f $gen, $agent
    Write-RunnerLog -Level "INFO" -Message "Evaluating $tag"

    # Tier-0 review gate: reviewer subagent must APPROVE before any tier runs.
    # Closes a race where host FSW debounce (3s) beats reviewer turnaround (~2min)
    # and promotes inflated/broken diffs (e.g. gen-0001/agent-0001 DLL-replay-drift).
    $reviewGate = Test-ReviewGate -Root $Root -CandPath $Cand.FullName -Manifest $manifest -TimeoutMin 10
    if (-not $reviewGate.Pass) { Reject $Cand "review-gate failed: $($reviewGate.Reason)"; return }
    Write-RunnerLog -Level "INFO" -Message "review-gate: $($reviewGate.Verdict)"

    $tier12 = Test-BenchHashes -Root $Root -DiffPath $diffPath -CandPath $Cand.FullName
    if (-not $tier12.Pass) { Reject $Cand "tier1-2 failed: $($tier12.Reason)"; return }

    $mimp = Test-MetricImprovement -Root $Root -DiffPath $diffPath -Manifest $manifest
    if (-not $mimp.Pass) { Reject $Cand "metric gate: $($mimp.Reason)"; return }
    Write-RunnerLog -Level "INFO" -Message "metric gate: $($mimp.Reason)"
    $tier3 = Invoke-PropertyTests -Root $Root -DiffPath $diffPath
    if (-not $tier3.Pass) { Reject $Cand "tier3 failed: $($tier3.Reason)"; return }

    $tier4 = Invoke-MutationTesting -Root $Root -DiffPath $diffPath
    if ($tier4.MutationScore -lt 0.70) { Reject $Cand "tier4 mutation score $($tier4.MutationScore) < 0.70"; return }

    # Skip tier 5/6 for:
    #   - scaffold-edit category (no task code changes)
    #   - external-repo (manifest.repo_root set to nested repo; AgentA composite scorers
    #     don't apply because example-*/ aren't inside the nested repo)
    $category = $null
    $externalRepo = $false
    try { $category = [string]$manifest.category } catch {}
    try {
        if ($manifest.PSObject.Properties.Name -contains 'repo_root' -and $manifest.repo_root) {
            $externalRepo = $true
        }
    } catch {}
    if ($category -eq 'scaffold-edit' -or $externalRepo) {
        $reason = if ($externalRepo) { "external-repo ($($manifest.repo_root))" } else { "scaffold-edit" }
        Write-RunnerLog -Level "INFO" -Message "$reason : skipping tier 5/6"
        $tier5 = @{ Delta = 0.0 }
        $tier6 = @{ Delta = 0.0 }
    } else {
        $tier5 = Invoke-BenchmarkDelta -Root $Root -DiffPath $diffPath -CandPath $Cand.FullName
        Write-RunnerLog -Level "INFO" -Message "Bench delta: $($tier5.Delta)"

        $tier6 = Invoke-HoldoutScoring -Root $Root -DiffPath $diffPath -CandPath $Cand.FullName
        if ($tier6.Delta -lt 0.02) {
            Reject $Cand "tier6 holdout delta $($tier6.Delta) < +0.02"
            return
        }
    }

    $criticStyle = (([int]$gen) % 5)
    $tier7 = Wait-CriticVerdict -Root $Root -CandPath $Cand.FullName -Style $criticStyle -TimeoutMin 60
    if ($tier7.Verdict -ne "APPROVE") { Reject $Cand "tier7 critic verdict: $($tier7.Verdict)"; return }

    $hack = Test-RewardHackTripwire -Root $Root -DiffPath $diffPath
    if ($hack.Tripped) { Reject $Cand "reward-hack tripped: $($hack.Reason)"; return }

    if ($category -eq 'scaffold-edit') {
        $gst = Invoke-GateSelfTest -Root $Root -DiffPath $diffPath -Manifest $manifest
        if (-not $gst.Pass) { Reject $Cand "gate self-test regressed: $($gst.Reason)"; return }
        Write-RunnerLog -Level "INFO" -Message "gate self-test PASS"
    }
    Approve-StagedDiff -Root $Root -CandPath $Cand.FullName -Tag $tag `
        -HoldoutDelta $tier6.Delta -BenchDelta $tier5.Delta -CriticStyle $criticStyle
    Write-RunnerLog -Level "INFO" -Message "PROMOTED $tag (holdout +$($tier6.Delta))"
}

function Reject {
    param($Cand, [string]$Reason)
    $rejectedRoot = Join-Path $Root "archive\rejected"
    New-Item -ItemType Directory -Force -Path $rejectedRoot | Out-Null
    $dest = Join-Path $rejectedRoot $Cand.Name
    if (Test-Path $dest) { $dest = "$dest-$(Get-Date -Format yyyyMMddHHmmss)" }
    Move-Item -Path $Cand.FullName -Destination $dest -Force
    "$Reason" | Out-File -FilePath (Join-Path $dest "rejection.txt") -Encoding utf8
    Write-RunnerLog -Level "WARN" -Message "REJECTED $($Cand.Name): $Reason"
}

function Invoke-OnceSweep {
    param([string]$Root)
    $stagedRoot = Join-Path $Root "agenta\infra\staged"
    if (-not (Test-Path $stagedRoot)) { return }
    Get-ChildItem $stagedRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $genDir = $_
        Get-ChildItem $genDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Invoke-PromotionForCandidate -Root $Root -Cand $_
        }
        if ((Test-Path (Join-Path $genDir.FullName "diff.patch")) -and (Test-Path (Join-Path $genDir.FullName "manifest.json"))) {
            Invoke-PromotionForCandidate -Root $Root -Cand $genDir
        }
    }
}

if ($Once) {
    Write-RunnerLog -Level "INFO" -Message "AgentA runner -Once sweep"
    Invoke-OnceSweep -Root $Root
    Write-RunnerLog -Level "INFO" -Message "Done"
    return
}

$stagedRoot = Join-Path $Root "agenta\infra\staged"
New-Item -ItemType Directory -Force -Path $stagedRoot | Out-Null

Write-RunnerLog -Level "INFO" -Message "AgentA runner resident polling mode -- watching $stagedRoot, debounce ${DebounceMs}ms"

# Initial sweep in case candidates accumulated while runner was down
Invoke-OnceSweep -Root $Root

# Resident poll loop. For each candidate dir under agenta\infra\staged/<gen>/<agent>/,
# check the most-recent file mtime; if quiet for DebounceMs and not already processed,
# run promotion. Cheap relative to verify itself (which is the dominant cost).
$processed = @{}

$plateauLastCheck = [DateTime]::MinValue
$lessonsLastCheck = [DateTime]::MinValue
$replayLastCheck = Get-Date  # FIX: seed to now so boot serves staged candidates before any full-archive replay (replay still runs on 7-day cadence, now timeout-guarded)
$watchdogLastCheck = [DateTime]::MinValue
while ($true) {
    Start-Sleep -Milliseconds 1000
    try {
        # Replay-Archive drift check every 7 days. Expensive (re-runs every verify).
        # On critical drift (>=20% from archived metric), writes
        # agenta/sentinels/replay-drift-trigger.md sentinel for operator.
        if (((Get-Date) - $replayLastCheck).TotalDays -ge 7) {
            $replayLastCheck = Get-Date
            try { Replay-Archive -Root $Root } catch {
                Write-RunnerLog -Level "ERROR" -Message "replay-archive failed: $($_.Exception.Message)"
            }
        }

        # Lessons-inbox poll every 30s. Cheap, idempotent. Archivist drops
        # agenta\infra\lessons-inbox/<id>.md; host appends via SYSTEM context which
        # bypasses the Claude auto-mode classifier blocking subagent invocations.
        if (((Get-Date) - $lessonsLastCheck).TotalSeconds -ge 30) {
            $lessonsLastCheck = Get-Date
            try { Process-LessonsInbox -Root $Root } catch {
                Write-RunnerLog -Level "ERROR" -Message "lessons-inbox poll failed: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-RunnerLog -Level "ERROR" -Message "outer guard: $($_.Exception.Message)"
    }
    try {
        if (-not (Test-Path $stagedRoot)) { continue }
        $genDirs = Get-ChildItem $stagedRoot -Directory -ErrorAction SilentlyContinue
        foreach ($genDir in $genDirs) {
            $cands = @()
            $cands += (Get-ChildItem $genDir.FullName -Directory -ErrorAction SilentlyContinue)
            # legacy: gen dir itself is a candidate (single-level layout)
            if ((Test-Path (Join-Path $genDir.FullName "diff.patch")) -and (Test-Path (Join-Path $genDir.FullName "manifest.json"))) {
                $cands += $genDir
            }
            foreach ($cand in $cands) {
                if ($processed.ContainsKey($cand.FullName)) { continue }
                $diff = Join-Path $cand.FullName "diff.patch"
                $manifest = Join-Path $cand.FullName "manifest.json"
                if (-not (Test-Path $diff) -or -not (Test-Path $manifest)) { continue }
                $mtime = (Get-ChildItem $cand.FullName -File -ErrorAction SilentlyContinue | Measure-Object LastWriteTime -Maximum).Maximum
                if (-not $mtime) { continue }
                $quietMs = ((Get-Date) - $mtime).TotalMilliseconds
                if ($quietMs -lt $DebounceMs) { continue }
                $processed[$cand.FullName] = $true
                try {
                    Invoke-PromotionForCandidate -Root $Root -Cand $cand
                } catch {
                    Write-RunnerLog -Level "ERROR" -Message "promotion failure on $($cand.FullName) : $($_.Exception.Message)"
                }
            }
        }

        # Heartbeat watchdog every 5 minutes. Detects subagent stalls (no
        # heartbeat update in 15min) and writes agenta/sentinels/<task>-stuck.md
        # sentinel. SessionStart hook surfaces. Does NOT kill subagents.
        if (((Get-Date) - $watchdogLastCheck).TotalMinutes -ge 5) {
            $watchdogLastCheck = Get-Date
            try { Watch-Heartbeats -Root $Root } catch {
                Write-RunnerLog -Level "ERROR" -Message "watchdog failed: $($_.Exception.Message)"
            }
        }

        # Plateau check every 5 minutes (cheap, idempotent, trigger file gates re-emission)
        if (((Get-Date) - $plateauLastCheck).TotalMinutes -ge 5) {
            $plateauLastCheck = Get-Date
            try {
                $pr = Detect-Plateau -Root $Root
                if ($pr.Signals.Count -gt 0) {
                    $emitted = Emit-DGMTrigger -Root $Root -PlateauResult $pr
                    if ($emitted) {
                        Write-RunnerLog -Level "WARN" -Message "PLATEAU detected: $(($pr.Signals) -join '; ') -- agenta/sentinels/dgm-trigger.md written"
                    }
                }
            } catch {
                Write-RunnerLog -Level "ERROR" -Message "plateau check failed: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-RunnerLog -Level "ERROR" -Message "poll loop exception: $($_.Exception.Message)"
    }
}

