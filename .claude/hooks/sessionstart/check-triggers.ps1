<#
.SYNOPSIS
  SessionStart hook. Surfaces AgentA host-runner trigger files as additional
  context for the new Claude Code GUI session.

.DESCRIPTION
  Host runner (SYSTEM context) writes trigger sentinels to workspace/ when it
  detects plateau, replay drift, or idle stall. Operator previously had to
  manually `cat agenta/sentinels/dgm-trigger.md` after opening Claude. This hook reads
  the sentinels and emits them via SessionStart hookSpecificOutput.additionalContext
  so they appear at the top of the new session automatically.

  Triggers checked (in priority order):
    1. agenta/sentinels/replay-drift-trigger.md  -- archived metric drift CRITICAL
    2. agenta/sentinels/dgm-trigger.md            -- plateau, run /dgm-improve
    3. agenta/sentinels/idle-trigger.md           -- nothing running, seed/pick task

  Also surfaces:
    - agenta\infra\orchestrate-queue/*.md     -- pending task suggestions

  Output: JSON to stdout per SessionStart hook contract. Stderr suppressed.
  Failures silent: never block session start over a hook error.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "SilentlyContinue"

try {
    $projectDir = $env:CLAUDE_PROJECT_DIR
    if (-not $projectDir -or -not (Test-Path $projectDir)) {
        $projectDir = "C:\Users\<user>\Documents\AgentA\AgentA"
    }
    if (-not (Test-Path $projectDir)) { exit 0 }

    $blocks = @()

    $replay = Join-Path $projectDir "agenta/sentinels/replay-drift-trigger.md"
    if (Test-Path $replay) {
        $content = Get-Content $replay -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $blocks += "## [CRITICAL] Replay drift detected`n`n$content`n`n_Source: agenta/sentinels/replay-drift-trigger.md_"
        }
    }

    $dgm = Join-Path $projectDir "agenta/sentinels/dgm-trigger.md"
    if (Test-Path $dgm) {
        $content = Get-Content $dgm -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $blocks += "## [PLATEAU] DGM trigger active`n`n$content`n`n_Source: agenta/sentinels/dgm-trigger.md_"
        }
    }

    $idle = Join-Path $projectDir "agenta/sentinels/idle-trigger.md"
    if (Test-Path $idle) {
        $content = Get-Content $idle -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $blocks += "## [IDLE] System has been idle`n`n$content`n`n_Source: agenta/sentinels/idle-trigger.md_"
        }
    }

    $queueDir = Join-Path $projectDir "agenta\infra\orchestrate-queue"
    if (Test-Path $queueDir) {
        $queued = @(Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        if ($queued.Count -gt 0) {
            $list = ($queued | ForEach-Object {
                $id = [IO.Path]::GetFileNameWithoutExtension($_.Name)
                "- ``/orchestrate $id`` (queued $([Math]::Round(((Get-Date) - $_.LastWriteTime).TotalHours,1))h ago)"
            }) -join "`n"
            $blocks += "## Orchestrate queue ($($queued.Count) pending)`n`n$list"
        }
    }

    if ($blocks.Count -eq 0) { exit 0 }

    $context = "# AgentA host-runner status`n`n" + ($blocks -join "`n`n---`n`n") + "`n`nDelete each trigger file after acting on it so the host runner can re-fire when the condition recurs."

    $out = @{
        hookSpecificOutput = @{
            hookEventName = "SessionStart"
            additionalContext = $context
        }
    } | ConvertTo-Json -Depth 5 -Compress

    [Console]::Out.WriteLine($out)
    exit 0
} catch {
    exit 0
}

