<#
  PostToolUse hook (any tool). Appends a JSONL record of tokens used per tool call to
  logs/tokens.jsonl. Subscription mode: tokens only, no cost_usd.

  Token counts come from the tool_response payload (Claude Code embeds usage when available).
#>
$input | Out-String | Set-Variable -Name raw
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$record = @{
    timestamp = (Get-Date).ToString("o")
    tool = $payload.tool_name
    session = $payload.session_id
    generation = $env:AGENTA_GENERATION
    tokens = 0
}

if ($payload.tool_response.usage) {
    $u = $payload.tool_response.usage
    $record.tokens = ($u.input_tokens + $u.output_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens) -as [int]
}

$root = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$logPath = Join-Path $root "logs\tokens.jsonl"
$line = $record | ConvertTo-Json -Compress
Add-Content -Path $logPath -Value $line -Encoding utf8

exit 0
