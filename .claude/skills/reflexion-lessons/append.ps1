<#
.SYNOPSIS
  Append an entry to LESSONS.md respecting the append-only NTFS ACL.
.DESCRIPTION
  LESSONS.md is OS-ACL'd: agent user has Allow{AppendData,ReadData,...} +
  Deny{WriteData,Delete,...}. Stock APIs (Add-Content, AppendAllText, '>>')
  request GENERIC_WRITE which the DENY rule blocks. We must open the handle
  with FILE_APPEND_DATA only.

  This script does exactly that. Pass an entry file (rendered lesson Markdown)
  or pipe content via -EntryText. Validates schema headers and brevity gate
  before writing.

.PARAMETER EntryFile
  Path to a file containing the rendered lesson entry.
.PARAMETER EntryText
  Alternative: pass the entry as a string.
.PARAMETER LessonsPath
  Override LESSONS.md location. Defaults to project root sibling.
.EXAMPLE
  .\append.ps1 -EntryFile workspace/task-42/lesson.md
.EXAMPLE
  echo "## [2026-...] Title`n..." | .\append.ps1
#>
[CmdletBinding()]
param(
    [string]$EntryFile = "",
    [string]$EntryText = "",
    [string]$LessonsPath = ""
)

if (-not $LessonsPath) {
    # Resolve project root: skill is at .claude/skills/reflexion-lessons/append.ps1
    $LessonsPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "LESSONS.md"
}

if ($EntryFile -and (Test-Path $EntryFile)) {
    $entry = Get-Content -Raw -Path $EntryFile
} elseif ($EntryText) {
    $entry = $EntryText
} else {
    # Read from stdin
    $entry = [Console]::In.ReadToEnd()
}

if (-not $entry) { throw "no entry content provided (use -EntryFile or -EntryText or stdin)" }

# Validation gates
if ($entry.Length -gt 4000) {
    throw "lesson too long ($($entry.Length) bytes; cap 4000 / ~300 words). Split into multiple lessons."
}
$required = @('**Context:**', '**Lesson:**', '**Why:**', '**How to apply:**', '**Source:**')
foreach ($r in $required) {
    if ($entry -notmatch [regex]::Escape($r)) {
        throw "lesson missing required header '$r'"
    }
}
if ($entry -notmatch '^##\s+\[\d{4}-\d{2}-\d{2}\]') {
    throw "lesson must start with '## [YYYY-MM-DD] <Title>' line"
}
if ($entry -notmatch '---\s*$') {
    # Ensure trailing separator
    $entry = $entry.TrimEnd() + "`n`n---`n"
}
if (-not $entry.StartsWith("`n")) { $entry = "`n" + $entry }

# Write via granular FileStream with AppendData-only rights
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($entry)
$fs = $null
try {
    $fs = New-Object System.IO.FileStream($LessonsPath,
        [IO.FileMode]::Append,
        [System.Security.AccessControl.FileSystemRights]::AppendData,
        [IO.FileShare]::Write,
        4096,
        [IO.FileOptions]::None)
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Flush()
} finally {
    if ($fs) { $fs.Dispose() }
}

Write-Output "appended $($bytes.Length) bytes to $LessonsPath"
