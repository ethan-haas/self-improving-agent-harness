<#
.SYNOPSIS
  Open Windows Sandbox with Claude Code GUI inside (subscription ToS-compliant).
.DESCRIPTION
  Loads host\sandbox-configs\critic-session.wsb. Sandbox auto-launches Claude Code GUI
  via LogonCommand. The human reviews the diff and produces a verdict via the
  /critic slash command. Verdict drops back into workspace\critic-inbox\<id>.verdict.json
  which the host runner is polling.

  Subscription compliance: every Claude execution is a human-opened GUI session.
  No --print, no headless, no ANTHROPIC_API_KEY in env.
#>
param([string]$RequestId)

$wsb = Join-Path $PSScriptRoot "sandbox-configs\critic-session.wsb"
if (-not (Test-Path $wsb)) {
    Write-Error "missing $wsb - run host\Install-AgentA.ps1 first"
    exit 1
}

# Write request-id file the sandbox LogonCommand will pick up
$root = Split-Path $PSScriptRoot
$inbox = Join-Path $root "workspace\sandbox-bootstrap"
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$RequestId | Out-File -FilePath (Join-Path $inbox "current-request.txt") -Encoding utf8

# Launch sandbox (operator clicks through Claude GUI inside)
Start-Process -FilePath $wsb -Verb Open
Write-Host "Sandbox opened for critic request $RequestId. Awaiting verdict in workspace\critic-inbox\$RequestId.verdict.json"
