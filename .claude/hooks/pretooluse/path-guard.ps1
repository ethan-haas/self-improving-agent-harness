<#
  PreToolUse hook for Write|Edit|MultiEdit. Denies writes outside agent-writable paths.
  Append-only paths (LESSONS.md) handled by OS ACL, not here.

  Updated Phase 2: AgentA infra moved from workspace/ to agenta/. Allow-list extended:
    agenta/tasks/**           - task code (where coder edits solver.py etc)
    agenta/infra/staged/**    - coder stages diff/manifest/etc here
    agenta/infra/lessons-inbox/** - archivist writes lesson files here
    agenta/infra/critic-inbox/**  - critic reads requests, writes verdicts here
    agenta/infra/outcomes/**  - coder/orchestrator write task summaries here
    agenta/infra/orchestrate-queue/**  - operator queues tasks here
    agenta/sentinels/**       - heartbeat/status/trigger/stuck files
    workspace/**              - LEGACY user projects (still writable)
    logs/**                   - per-tool token accounting etc
    .claude/skills/**         - meta-improver writes new skills via staging

  Deny list unchanged: bench, archive, host, holdout, .claude/{agents,hooks,settings.json},
  LESSONS.md, tests/sealed.
#>
$input | Out-String | Set-Variable -Name raw
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$path = $payload.tool_input.file_path
if (-not $path) { exit 0 }

$abs = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $PWD $path }
$abs = [IO.Path]::GetFullPath($abs).Replace('\','/')

$allowedPrefixes = @(
    'workspace/',
    'logs/',
    'agenta/tasks/',
    'agenta/infra/staged/',
    'agenta/infra/lessons-inbox/',
    'agenta/infra/critic-inbox/',
    'agenta/infra/outcomes/',
    'agenta/infra/orchestrate-queue/',
    'agenta/infra/host-patches/',
    'agenta/sentinels/',
    'agenta/state/',
    '.claude/skills/'
)

$deniedPrefixes = @(
    'bench/',
    'archive/',
    'host/',
    'holdout/',
    '.claude/agents/',
    '.claude/hooks/',
    '.claude/commands/',
    '.claude/settings.json',
    'LESSONS.md',
    'tests/sealed/'
)

foreach ($p in $deniedPrefixes) {
    if ($abs -match [regex]::Escape($p)) {
        [Console]::Error.WriteLine("DENY: path-guard blocked write to protected path: $path")
        exit 2
    }
}

$projectRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path.Replace('\','/')
if ($abs.StartsWith($projectRoot)) {
    $rel = $abs.Substring($projectRoot.Length).TrimStart('/')
    $allowed = $false
    foreach ($pref in $allowedPrefixes) {
        if ($rel.StartsWith($pref)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        [Console]::Error.WriteLine("DENY: path-guard - write to '$rel' not in allow-list (workspace/, logs/, agenta/tasks/, agenta/infra/{staged,lessons-inbox,critic-inbox,outcomes,orchestrate-queue,host-patches}, agenta/sentinels/, agenta/state/, .claude/skills/)")
        exit 2
    }
}

exit 0
