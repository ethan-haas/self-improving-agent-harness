<#
  PostToolUse hook for Bash. After a successful `git commit`, write a lineage stamp into
  the commit body via git notes (the commit itself is already made; we attach metadata
  the host runner can use to tag archive/gen-NNNN/agent-MMMM).
#>
$input | Out-String | Set-Variable -Name raw
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $payload.tool_input.command
if ($cmd -notmatch 'git\s+commit') { exit 0 }

# Only act if the commit succeeded
$exitCode = $payload.tool_response.exit_code
if ($null -ne $exitCode -and $exitCode -ne 0) { exit 0 }

$gen = $env:AGENTA_GENERATION
$parent = $env:AGENTA_PARENT
if (-not $gen -or -not $parent) { exit 0 }

# Attach via git notes (doesn't rewrite the commit, doesn't affect hashes)
try {
    git notes add -m "agenta-generation: $gen`nagenta-parent: $parent`nagenta-timestamp: $(Get-Date -Format o)" HEAD 2>&1 | Out-Null
} catch {
    # non-fatal
}

exit 0
