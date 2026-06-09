<#
  PreToolUse hook for Bash. Reads tool input from stdin (JSON), denies dangerous commands.
  Exit 0 = allow, exit 2 = deny with reason on stderr.
#>
$input | Out-String | Set-Variable -Name raw
if (-not $raw) { exit 0 }

try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }
$cmd = $payload.tool_input.command
if (-not $cmd) { exit 0 }

$denylist = @(
    'rm\s+-rf\s+/',                 # nuke root
    'rm\s+-rf\s+~',                 # nuke home
    'rm\s+-rf\s+\.\s*$',            # nuke cwd
    '\bdd\s+if=',                   # raw disk
    'mkfs\.',                       # format
    '>\s*/dev/(sda|nvme|hd)',       # write to raw device
    '\bicacls\b',                   # ACL grant attempt
    '\bSet-Acl\b',                  # ACL grant attempt
    '\battrib\s+-r\b',              # remove read-only
    '--no-verify',                  # bypass git hooks
    '--no-gpg-sign',                # bypass signing
    'git\s+push\s+.*--force\s+.*\b(main|master)\b',  # force-push to main
    'git\s+reset\s+--hard\s+origin',                  # destructive reset
    'curl.*\|\s*(bash|sh|powershell|pwsh)',           # remote-execute
    '\bwget.*\|\s*(bash|sh)',                         # remote-execute
    '\bIEX\b',                                        # IEX(...)
    'Invoke-Expression',                              # eval
    'ANTHROPIC_API_KEY=',                             # API key in env (subscription mode forbids)
    'claude\s+-p\b',                                  # headless API call (subscription mode)
    'claude\s+--print\b'                              # headless API call (subscription mode)
)

foreach ($p in $denylist) {
    if ($cmd -match $p) {
        [Console]::Error.WriteLine("DENY: bash-guard matched pattern '$p' in command: $cmd")
        exit 2
    }
}

exit 0
