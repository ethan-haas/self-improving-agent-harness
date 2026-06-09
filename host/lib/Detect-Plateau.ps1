<#
  Plateau detection for the autoresearch outer loop.

  Signals (any triggers a DGM-improve nudge):
    1. >= 10 rejections since the last promotion (single task class stuck)
    2. No promotion in last 24h (overall throughput collapse)
    3. Last 3 promotions' holdout_delta all < 0.05 (diminishing returns -> scaffold ceiling)

  Separate idle-stall signal (Emit-IdleTrigger):
    4. agenta\infra\staged/ empty AND no rejections in 6h AND no promotions in 6h
       AND runner uptime > 4h -> system silently stalled, operator hasn't run
       /orchestrate. Surface via agenta/sentinels/idle-trigger.md so SessionStart hook
       can prompt operator to seed a task or pick from queue.

  Trigger files persist until operator deletes them. Prevents repeated firing.
#>
function Detect-Plateau {
    param([string]$Root)

    $archiveDir = Join-Path $Root "archive"
    $rejectedDir = Join-Path $archiveDir "rejected"

    $promoted = @()
    if (Test-Path $archiveDir) {
        $promoted = Get-ChildItem $archiveDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^gen-\d+$' } |
            Sort-Object LastWriteTime -Descending
    }
    $rejected = @()
    if (Test-Path $rejectedDir) {
        $rejected = Get-ChildItem $rejectedDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    }

    $signals = @()

    if ($promoted.Count -gt 0) {
        $lastPromote = $promoted[0].LastWriteTime
        $recentRejects = @($rejected | Where-Object { $_.LastWriteTime -gt $lastPromote }).Count
        if ($recentRejects -ge 10) {
            $signals += "10+ rejections ($recentRejects) since last promotion at $($lastPromote.ToString('o'))"
        }
    } elseif ($rejected.Count -ge 10) {
        $signals += "10+ rejections and zero promotions"
    }

    if ($promoted.Count -gt 0) {
        $hours = ((Get-Date) - $promoted[0].LastWriteTime).TotalHours
        if ($hours -ge 24) {
            $signals += ("no promotion in {0:N1}h" -f $hours)
        }
    }

    if ($promoted.Count -ge 3) {
        $internalPromoted = @()
        foreach ($p in $promoted) {
            $sf = Get-ChildItem $p.FullName -Recurse -Filter scores.json -ErrorAction SilentlyContinue | Select-Object -First 1
            $mf = Get-ChildItem $p.FullName -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | Select-Object -First 1
            $isExternal = $false
            if ($mf) {
                try {
                    $mj = Get-Content $mf.FullName -Raw | ConvertFrom-Json
                    if ($mj.repo_root -or $mj.category -eq 'scaffold-edit') { $isExternal = $true }
                } catch {}
            }
            if (-not $isExternal -and $sf) {
                try {
                    $s = Get-Content $sf.FullName -Raw | ConvertFrom-Json
                    $internalPromoted += [double]$s.holdout_delta
                } catch {}
            }
            if ($internalPromoted.Count -ge 3) { break }
        }
        if ($internalPromoted.Count -ge 3 -and @($internalPromoted | Where-Object { $_ -lt 0.05 }).Count -eq 3) {
            $signals += ("last 3 internal-task holdout deltas all < 0.05: {0}" -f ($internalPromoted -join ', '))
        }
    }

    # Signal 3b (external-repo): per-task metric progression. External tasks record
    # holdout_delta=0 (tier5/6 skipped), so the holdout signal above never fires for
    # them. Use the task's own metric_value series (recorded by Approve-StagedDiff).
    # Fires when the latest external task's two most-recent consecutive metric
    # improvements are both < 1%. Restores DGM plateau detection for external-repo.
    if ($promoted.Count -ge 3) {
        $rowsE = @()
        foreach ($p in $promoted) {
            $sf = Get-ChildItem $p.FullName -Recurse -Filter scores.json -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $sf) { continue }
            try { $s = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $s.repo_root) { continue }
            $rowsE += [pscustomobject]@{
                gen = [int]([regex]::Match($p.Name,'\d+').Value)
                task = [string]$s.task_id
                metric = $s.metric_value
                dir = $(if ($s.metric_direction) { [string]$s.metric_direction } else { 'lower_is_better' })
            }
        }
        if ($rowsE.Count -ge 3) {
            $latestTask = ($rowsE | Sort-Object gen)[-1].task
            $series = @($rowsE | Where-Object { $_.task -eq $latestTask } | Sort-Object gen | Select-Object -Last 3)
            if ($series.Count -ge 3) {
                $rels = @()
                for ($i = 1; $i -lt $series.Count; $i++) {
                    $prev = [double]$series[$i-1].metric; $cur = [double]$series[$i].metric
                    if ($prev -eq 0) { continue }
                    if ($series[$i].dir -eq 'higher_is_better') { $rels += ($cur - $prev) / [math]::Abs($prev) }
                    else { $rels += ($prev - $cur) / [math]::Abs($prev) }
                }
                $recent2 = @($rels | Select-Object -Last 2)
                if ($recent2.Count -eq 2 -and @($recent2 | Where-Object { $_ -lt 0.01 }).Count -eq 2) {
                    $signals += ("external task '$latestTask' diminishing: last 2 metric improvements " + (($recent2 | ForEach-Object { '{0:P2}' -f $_ }) -join ', ') + " both < 1%")
                }
            }
        }
    }
    # Side effect: idle-stall detection + emission. Runs every plateau-check pass.
    # Separated from $signals because idle is a distinct condition (system off vs
    # progress slow). Emit-IdleTrigger is idempotent (won't re-fire while trigger
    # file exists), so cheap to call on every poll.
    try {
        $idle = Detect-IdleStall -Root $Root
        if ($idle.Stalled) { [void](Emit-IdleTrigger -Root $Root -IdleResult $idle) }
    } catch {}

    return @{ Signals = $signals; LastPromoted = ($promoted | Select-Object -First 1); RejectedCount = $rejected.Count }
}

function Emit-DGMTrigger {
    param([string]$Root, $PlateauResult)
    if ($PlateauResult.Signals.Count -eq 0) { return $false }

    $triggerFile = Join-Path $Root "agenta/sentinels/dgm-trigger.md"
    if (Test-Path $triggerFile) {
        return $false
    }

    $body = @"
# DGM /dgm-improve trigger

Plateau detected at $((Get-Date).ToString('o')).

## Signals
$($PlateauResult.Signals | ForEach-Object { "- $_" } | Out-String)

## Suggested action
Open Claude Code in this directory and run:

``````
/dgm-improve
``````

The meta-improver will read archive lineage, identify the gap, propose a scaffold mutation, and stage it.

## Clear this trigger
Delete this file (agenta/sentinels/dgm-trigger.md) after running /dgm-improve so future plateau detections can fire.
"@
    [System.IO.File]::WriteAllText($triggerFile, $body, [Text.UTF8Encoding]::new($false))

    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text "AgentA plateau", ($PlateauResult.Signals[0]) -ErrorAction SilentlyContinue
        }
    } catch {}

    try {
        $localSettings = Join-Path $Root ".claude\settings.local.json"
        if (Test-Path $localSettings) {
            $local = Get-Content $localSettings -Raw | ConvertFrom-Json
            if ($local.env.HEALTHCHECKS_URL) {
                Invoke-RestMethod -Uri ($local.env.HEALTHCHECKS_URL + "/fail") -Method Post -Body "plateau: $($PlateauResult.Signals -join '; ')" -TimeoutSec 10
            }
        }
    } catch {}

    return $true
}

<#
  Idle-stall detector. Distinct from plateau (plateau = progress slows, idle =
  system not running at all). Fires when:
    - agenta\infra\staged/ has zero candidate dirs (operator hasn't dispatched)
    - last rejection > 6h ago (or none ever)
    - last promotion > 6h ago (or none ever)
    - runner uptime > 4h (avoid false-fire on fresh boot)

  Uptime measured via host\logs\runner.log first BOOT marker after most recent
  service restart. Falls back to file mtime if log absent.
#>
function Detect-IdleStall {
    param([string]$Root)

    $stagedRoot = Join-Path $Root "agenta\infra\staged"
    $stagedCount = 0
    if (Test-Path $stagedRoot) {
        $stagedCount = @(Get-ChildItem $stagedRoot -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path (Join-Path $_.FullName "diff.patch")) -and
                (Test-Path (Join-Path $_.FullName "manifest.json"))
            }).Count
    }
    if ($stagedCount -gt 0) { return @{ Stalled = $false; Reason = "staged work present ($stagedCount)" } }

    $archiveDir = Join-Path $Root "archive"
    $rejectedDir = Join-Path $archiveDir "rejected"
    $now = Get-Date

    $lastPromote = $null
    if (Test-Path $archiveDir) {
        $p = Get-ChildItem $archiveDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^gen-\d+$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($p) { $lastPromote = $p.LastWriteTime }
    }
    $lastReject = $null
    if (Test-Path $rejectedDir) {
        $r = Get-ChildItem $rejectedDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($r) { $lastReject = $r.LastWriteTime }
    }

    $promoteAgeH = if ($lastPromote) { ($now - $lastPromote).TotalHours } else { [double]::PositiveInfinity }
    $rejectAgeH = if ($lastReject) { ($now - $lastReject).TotalHours } else { [double]::PositiveInfinity }

    if ($promoteAgeH -lt 6 -or $rejectAgeH -lt 6) {
        return @{ Stalled = $false; Reason = ("recent activity: promote={0:N1}h reject={1:N1}h" -f $promoteAgeH, $rejectAgeH) }
    }

    $uptimeH = 0.0
    $logFile = Join-Path $Root "logs\runner.log"
    if (Test-Path $logFile) {
        try {
            $bootLine = Get-Content $logFile -Tail 5000 | Where-Object { $_ -match '\[BOOT\]' } | Select-Object -Last 1
            if ($bootLine -and $bootLine -match '\[([^\]]+)\]') {
                $bootTime = [DateTime]::Parse($matches[1])
                $uptimeH = ($now - $bootTime).TotalHours
            }
        } catch {}
    }
    if ($uptimeH -lt 4) {
        return @{ Stalled = $false; Reason = ("runner uptime {0:N1}h < 4h" -f $uptimeH) }
    }

    return @{
        Stalled = $true
        PromoteAgeH = $promoteAgeH
        RejectAgeH = $rejectAgeH
        UptimeH = $uptimeH
    }
}

function Emit-IdleTrigger {
    param([string]$Root, $IdleResult)
    if (-not $IdleResult.Stalled) { return $false }

    $triggerFile = Join-Path $Root "agenta/sentinels/idle-trigger.md"
    if (Test-Path $triggerFile) { return $false }

    $promoteStr = if ([double]::IsPositiveInfinity($IdleResult.PromoteAgeH)) { "never" } else { ("{0:N1}h ago" -f $IdleResult.PromoteAgeH) }
    $rejectStr = if ([double]::IsPositiveInfinity($IdleResult.RejectAgeH)) { "never" } else { ("{0:N1}h ago" -f $IdleResult.RejectAgeH) }

    $queueDir = Join-Path $Root "agenta\infra\orchestrate-queue"
    $queued = @()
    if (Test-Path $queueDir) {
        $queued = Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    }
    $queueBlock = if ($queued.Count -gt 0) {
        ($queued | ForEach-Object { "- ``$($_.Name)``" }) -join "`n"
    } else {
        "(empty - seed one via ``agenta\infra\orchestrate-queue/<task>.md``)"
    }

    $body = @"
# Idle-stall trigger

System has been idle since $((Get-Date).ToString('o')).

## Signals
- Last promotion: $promoteStr
- Last rejection: $rejectStr
- Runner uptime: $("{0:N1}h" -f $IdleResult.UptimeH)
- ``agenta\infra\staged/`` is empty

## Queue
$queueBlock

## Suggested action
Open Claude Code GUI in this directory and either:

1. Pick a task from the queue: ``/orchestrate <task-id>``
2. Seed a new task: write a spec to ``bench/tasks/<id>.md`` (host-mediated) or ``agenta\infra\orchestrate-queue/<id>.md``, then ``/orchestrate <id>``
3. Run scaffold improvement: ``/dgm-improve``

## Clear this trigger
Delete this file (``agenta/sentinels/idle-trigger.md``) after dispatching work so future idle detections can fire.
"@
    [System.IO.File]::WriteAllText($triggerFile, $body, [Text.UTF8Encoding]::new($false))
    return $true
}
