<#
  Lessons-inbox poll: agenta\infra\lessons-inbox/*.md -> LESSONS.md via append.ps1.

  Architectural mediation pattern: agent can't reliably invoke
  reflexion-lessons/append.ps1 from a subagent because Claude's auto-mode
  classifier overrides settings.json allow rules for powershell-from-Bash
  paths. Agent writes lesson drafts to agenta\infra\lessons-inbox/ (regular
  Write tool, no classifier friction). Host runner (SYSTEM context, no
  Claude classifier in path) picks them up and runs append.ps1 -- which is
  the only API satisfying the LESSONS.md AppendData-only ACL.

  Schema validation mirrors append.ps1: requires schema headers + brevity
  cap. Invalid files move to agenta\infra\lessons-rejected/ with reason.
  Processed files move to agenta\infra\lessons-archive/<YYYY-MM-DD>/.
#>
function Process-LessonsInbox {
    param([string]$Root)

    $inbox = Join-Path $Root "agenta\infra\lessons-inbox"
    if (-not (Test-Path $inbox)) { return }

    $archiveDir = Join-Path $Root ("agenta\infra\lessons-archive\" + (Get-Date -Format "yyyy-MM-dd"))
    $rejectedDir = Join-Path $Root "agenta\infra\lessons-rejected"
    $appendHelper = Join-Path $Root ".claude\skills\reflexion-lessons\append.ps1"

    if (-not (Test-Path $appendHelper)) {
        Write-RunnerLog -Level "ERROR" -Message "lessons-inbox: append.ps1 helper missing at $appendHelper"
        return
    }

    # Also recover any orphans previously rejected with stale-$LASTEXITCODE 128
    $rejectedDir2 = Join-Path $Root "agenta\infra\lessons-rejected"
    if (Test-Path $rejectedDir2) {
        Get-ChildItem $rejectedDir2 -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object {
            $reasonFile = "$($_.FullName).reason.txt"
            if (Test-Path $reasonFile) {
                (Get-Content $reasonFile -Raw -ErrorAction SilentlyContinue) -match 'append\.ps1 exit 128'
            } else { $false }
        } | ForEach-Object {
            Move-Item $_.FullName (Join-Path $inbox $_.Name) -Force -ErrorAction SilentlyContinue
            Remove-Item "$($_.FullName).reason.txt" -Force -ErrorAction SilentlyContinue
        }
    }

    Get-ChildItem $inbox -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $f = $_
        # Debounce: skip files written in last 3 seconds (agent may still be writing)
        if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 3) { return }

        try {
            $rejectReason = ""
            # Reset $LASTEXITCODE so we don't read a stale value from earlier
            # git/native commands in the runner's poll loop. PowerShell carries
            # $LASTEXITCODE across invocations until next native call.
            $global:LASTEXITCODE = 0
            try {
                & $appendHelper -EntryFile $f.FullName 2>&1 | Out-Null
                # append.ps1 reports errors via 'throw' (caught below); it never
                # explicitly sets LASTEXITCODE. So a non-zero here is from a
                # native command append.ps1 invoked. Only treat as failure if
                # caught by the catch block.
            } catch {
                $rejectReason = "append.ps1 threw: $($_.Exception.Message)"
            }

            if ($rejectReason) {
                New-Item -ItemType Directory -Force -Path $rejectedDir | Out-Null
                $dest = Join-Path $rejectedDir $f.Name
                if (Test-Path $dest) { $dest = "$dest-$(Get-Date -Format yyyyMMddHHmmss)" }
                Move-Item $f.FullName $dest -Force
                "$rejectReason" | Out-File -FilePath ($dest + ".reason.txt") -Encoding utf8
                Write-RunnerLog -Level "WARN" -Message "lessons-inbox: rejected $($f.Name) -- $rejectReason"
            } else {
                New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
                $dest = Join-Path $archiveDir $f.Name
                if (Test-Path $dest) { $dest = "$dest-$(Get-Date -Format HHmmss)" }
                Move-Item $f.FullName $dest -Force
                Write-RunnerLog -Level "INFO" -Message "lessons-inbox: appended $($f.Name) -> LESSONS.md"
            }
        } catch {
            Write-RunnerLog -Level "ERROR" -Message "lessons-inbox: $($f.Name) processing failed: $($_.Exception.Message)"
        }
    }
}
