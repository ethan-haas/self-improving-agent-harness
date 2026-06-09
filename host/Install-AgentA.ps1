<#
.SYNOPSIS
  One-time installer for AgentA. Run as Administrator.
.DESCRIPTION
  - Creates holdout.vhdx (BitLocker-encrypted, 1 GB default)
  - Applies NTFS ACLs (DENY-write on bench/, archive/, host/, .claude/agents/, .claude/hooks/)
  - Applies append-only ACL mask on LESSONS.md
  - Registers Task Scheduler job for host\runner.ps1 (SYSTEM, every 5 min)
  - Registers daily report job at 00:05 local
#>
[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot))

$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    throw "Run as Administrator"
}

Write-Host "[1/5] Creating holdout/ (ACL-only mode, no BitLocker)..."
$holdoutDir = Join-Path $Root "holdout"
$vhdxLegacy = Join-Path $Root "holdout.vhdx"

# Cleanup legacy VHDX if present
if (Test-Path $vhdxLegacy) {
    Write-Host "  removing legacy holdout.vhdx (BitLocker mode deprecated)..."
    Dismount-VHD -Path $vhdxLegacy -ErrorAction SilentlyContinue
    Remove-Item $vhdxLegacy -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $holdoutDir)) {
    New-Item -ItemType Directory -Path $holdoutDir | Out-Null
}
# Seed a placeholder score.py if none yet -- host runner needs SOMETHING to invoke
$scorePy = Join-Path $holdoutDir "score.py"
if (-not (Test-Path $scorePy)) {
    @'
"""holdout/score.py - placeholder. Replace with actual sealed eval logic.

Invoked by host\lib\Invoke-HoldoutScoring.ps1 with sandbox-applied diff root as argv[1].
Must print a single float to stdout. NEVER readable from agent user (NTFS DENY-read).
"""
import sys
print("0.0")
'@ | Out-File -FilePath $scorePy -Encoding utf8
}
Write-Host "  holdout/ ready -- ACL will deny read for agent user below"

Write-Host "[2/5] Setting NTFS ACLs..."
# Resolve current user to a NTAccount/SID explicitly. $env:USERNAME alone fails on some
# systems with "Some or all identity references could not be translated."
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$agentAccount = $currentSid.Translate([Security.Principal.NTAccount])
Write-Host "  agent identity: $agentAccount (SID $currentSid)"

$protected = @("bench", "archive", "host", ".claude\agents", ".claude\hooks")
foreach ($rel in $protected) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path $path)) { continue }
    $acl = Get-Acl $path
    # IMPORTANT: enumerate specific write rights. "Modify" is a composite that includes
    # Read, so DENY-Modify would also block Read for the same SID (even with admin token).
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $agentAccount,
        "WriteData,AppendData,Delete,DeleteSubdirectoriesAndFiles,WriteAttributes,WriteExtendedAttributes,ChangePermissions,TakeOwnership",
        "ContainerInherit,ObjectInherit", "None", "Deny")
    $acl.SetAccessRule($rule)
    Set-Acl -Path $path -AclObject $acl
}
Write-Host "  DENY-write applied to $($protected -join ', ')"

# Holdout: DENY-read AND DENY-write for agent user. Only SYSTEM (host runner) can read.
$holdoutPath = Join-Path $Root "holdout"
if (Test-Path $holdoutPath) {
    $acl = Get-Acl $holdoutPath
    $denyAll = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $agentAccount, "FullControl", "ContainerInherit,ObjectInherit", "None", "Deny")
    $acl.SetAccessRule($denyAll)
    Set-Acl -Path $holdoutPath -AclObject $acl
    Write-Host "  DENY-all (read+write) applied to holdout/ for $agentAccount"
}

Write-Host "[3/5] Append-only ACL on LESSONS.md..."
$lessons = Join-Path $Root "LESSONS.md"
if (-not (Test-Path $lessons)) { "# AgentA Lessons`n`n" | Out-File -FilePath $lessons -Encoding utf8 }
$acl = Get-Acl $lessons
$append = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $agentAccount, "AppendData,ReadData,ReadAttributes,ReadExtendedAttributes,ReadPermissions", "None", "None", "Allow")
$deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $agentAccount, "WriteData,WriteExtendedAttributes,Delete,DeleteSubdirectoriesAndFiles", "None", "None", "Deny")
$acl.SetAccessRule($append)
$acl.SetAccessRule($deny)
Set-Acl -Path $lessons -AclObject $acl
Write-Host "  LESSONS.md is append-only for $agentAccount"

Write-Host "[4/5] Registering Task Scheduler runner..."
$runnerXml = Join-Path $PSScriptRoot "agenta-runner.xml"
if (-not (Test-Path $runnerXml)) {
    Write-Host "  agenta-runner.xml not found - skipping (see host\agenta-runner.xml template)"
} else {
    Register-ScheduledTask -Xml (Get-Content $runnerXml -Raw) -TaskName "AgentA-Runner" -Force | Out-Null
    Write-Host "  AgentA-Runner registered (SYSTEM, every 5 min)"
}

Write-Host "[5/5] Registering daily report..."
$reportTrigger = New-ScheduledTaskTrigger -Daily -At "00:05"
$reportAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -Command `". '$Root\host\lib\Send-DailyReport.ps1'; Send-DailyReport -Root '$Root'`""
Register-ScheduledTask -TaskName "AgentA-DailyReport" -Trigger $reportTrigger -Action $reportAction `
    -RunLevel Highest -User "SYSTEM" -Force | Out-Null

Write-Host ""
Write-Host "AgentA install complete."
Write-Host "Next: copy .claude\settings.local.json.example to .claude\settings.local.json and fill in."
