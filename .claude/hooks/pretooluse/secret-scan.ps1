<#
  PreToolUse hook for Write|Edit. Blocks writes containing high-entropy strings or known
  secret prefixes (AKIA, ghp_, sk-, anthropic-api-key, AWS keys, etc.).
#>
$input | Out-String | Set-Variable -Name raw
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$content = $payload.tool_input.content
if (-not $content) { $content = $payload.tool_input.new_string }
if (-not $content) { exit 0 }

# Known prefixes
$secretPatterns = @(
    'AKIA[0-9A-Z]{16}',                        # AWS access key
    'aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}',
    'ghp_[A-Za-z0-9]{36}',                     # GitHub personal access token
    'gho_[A-Za-z0-9]{36}',
    'ghu_[A-Za-z0-9]{36}',
    'sk-ant-api03-[A-Za-z0-9_\-]{48,}',        # Anthropic API key
    'sk-[A-Za-z0-9]{48,}',                     # OpenAI / generic
    '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----',
    'xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]{24,}',     # Slack bot token
    'ANTHROPIC_API_KEY\s*=\s*["'']?sk-'        # env-var assignment
)

foreach ($p in $secretPatterns) {
    if ($content -match $p) {
        [Console]::Error.WriteLine("DENY: secret-scan matched pattern '$p' - content contains a probable secret")
        exit 2
    }
}

# Entropy heuristic for long unbroken alphanumeric runs (>40 chars, entropy > 4.5)
$matches = [regex]::Matches($content, '[A-Za-z0-9+/=_\-]{40,}')
foreach ($m in $matches) {
    $s = $m.Value
    $hist = @{}
    foreach ($c in $s.ToCharArray()) { if ($hist.ContainsKey($c)) { $hist[$c]++ } else { $hist[$c] = 1 } }
    $len = $s.Length
    $entropy = 0.0
    foreach ($v in $hist.Values) { $p = $v / $len; $entropy -= $p * [Math]::Log($p, 2) }
    if ($entropy -gt 4.5) {
        [Console]::Error.WriteLine("WARN: secret-scan high-entropy string (H=$entropy) in write - review: $($s.Substring(0, [Math]::Min(20,$s.Length)))...")
        # Warn, don't block - many legitimate hashes have high entropy
    }
}

exit 0
