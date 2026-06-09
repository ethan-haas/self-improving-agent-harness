<#
  Heartbeat watchdog for subagent activity.

  Coder subagent writes agenta/sentinels/<task>-heartbeat.json every autoresearch
  iteration with timestamp + current best metric + current action. This
  watchdog detects subagent stalls (no update within 15min) and writes a
  sentinel that SessionStart hook surfaces.

  Heartbeat schema:
    {
      "task": "<task-id>",
      "iter": <int>,
      "ts": "<ISO timestamp>",
      "last_metric": <float>,
      "best_metric": <float>,
      "last_action": "<short description>",
      "elapsed_s": <float since loop start>
    }

  Watchdog logic:
    1. Find all agenta/sentinels/*-heartbeat.json
    2. For each: read ts, compute age
    3. If age >15min AND file mtime within session window (last 8h) -> stuck
    4. Write agenta/sentinels/<task>-stuck.md sentinel (idempotent)
    5. If heartbeat file removed (subagent completed) -> remove stuck sentinel

  IMPORTANT: this does NOT timeout running subagents. It just SIGNALS the
  operator. Subagent keeps running. Operator decides whether to interrupt.
#>
function Watch-Heartbeats {
    param([string]$Root, [int]$StaleMinutes = 15)

    $workspaceDir = Join-Path $Root "workspace"
    if (-not (Test-Path $workspaceDir)) { return }

    $heartbeats = Get-ChildItem $workspaceDir -Filter "*-heartbeat.json" -File -ErrorAction SilentlyContinue
    $now = Get-Date

    foreach ($hb in $heartbeats) {
        $taskId = $hb.Name -replace '-heartbeat\.json$', ''
        $stuckFile = Join-Path $workspaceDir "$taskId-stuck.md"

        $hbContent = $null
        try { $hbContent = Get-Content $hb.FullName -Raw | ConvertFrom-Json } catch {}

        $ageMin = ($now - $hb.LastWriteTime).TotalMinutes

        if ($ageMin -le $StaleMinutes) {
            # Heartbeat fresh. Clear any stale stuck sentinel.
            if (Test-Path $stuckFile) {
                Remove-Item $stuckFile -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        # File mtime older than 8h means session likely ended; not a stall, just old.
        if ($ageMin -gt 480) { continue }

        # Stuck. Write sentinel (idempotent — skip if exists + recent).
        if (Test-Path $stuckFile) {
            $stuckAge = ($now - (Get-Item $stuckFile).LastWriteTime).TotalMinutes
            if ($stuckAge -lt 30) { continue }
        }

        $iter = "?"
        $bestMetric = "?"
        $lastAction = "?"
        $lastTs = $hb.LastWriteTime.ToString('o')
        if ($hbContent) {
            try { $iter = [string]$hbContent.iter } catch {}
            try { $bestMetric = [string]$hbContent.best_metric } catch {}
            try { $lastAction = [string]$hbContent.last_action } catch {}
            try { $lastTs = [string]$hbContent.ts } catch {}
        }

        $body = @"
# Subagent appears stuck: $taskId

Heartbeat last updated $((Get-Date $hb.LastWriteTime).ToString('o')) ($([int]$ageMin) minutes ago, threshold $StaleMinutes min).

## Last known state
- iter: $iter
- best_metric: $bestMetric
- last_action: $lastAction
- last_ts: $lastTs

## What to check
1. ``cat workspace/$($taskId)-heartbeat.json`` — confirm staleness
2. ``Get-Process -Name uv,python,bash | Sort-Object CPU -Descending`` — is verify cmd actually running?
3. Tail the subagent's run.log inside ``workspace/$taskId/`` if present
4. If subagent is hung (not just slow): Ctrl-C the parent /orchestrate session, re-run, outer-loop reads heartbeat and skips already-tried configs

## What this is NOT
This sentinel doesn't kill the subagent. It just flags potential stall. A long-running but **progressing** task should write fresh heartbeats; absence of update is the only stall signal.

## Clear this sentinel
Delete ``workspace/$($taskId)-stuck.md`` after handling. Watchdog refires if heartbeat stays stale.
"@
        [System.IO.File]::WriteAllText($stuckFile, $body, [Text.UTF8Encoding]::new($false))
        Write-RunnerLog -Level "WARN" -Message "watchdog: $taskId heartbeat stale ${ageMin}min -> $stuckFile"
    }
}
