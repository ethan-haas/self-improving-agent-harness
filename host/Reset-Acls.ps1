<#
.SYNOPSIS
  Reset NTFS ACLs on AgentA protected paths. Recovery from over-broad DENY rules.
.DESCRIPTION
  Uses takeown.exe + icacls.exe (SeTakeOwnershipPrivilege bypasses DACL) to recover
  from any state where Install-AgentA applied too-broad DENY rules. Run as Admin.
  After this runs, re-run Setup-AgentA.ps1 to apply correct ACLs.
#>
[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot))

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    throw "Run as Administrator"
}

$paths = @(
    "$Root\host", "$Root\bench", "$Root\archive", "$Root\holdout",
    "$Root\.claude\agents", "$Root\.claude\hooks"
)

foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "takeown: $p"
        takeown.exe /F $p /R /A /D Y | Out-Null
    }
}
if (Test-Path "$Root\LESSONS.md") {
    takeown.exe /F "$Root\LESSONS.md" /A | Out-Null
}

foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "icacls reset: $p"
        icacls.exe $p /reset /T /C /Q | Out-Null
    }
}
if (Test-Path "$Root\LESSONS.md") {
    icacls.exe "$Root\LESSONS.md" /reset /C /Q | Out-Null
}

Write-Host ""
Write-Host "ACLs reset. Re-run Setup-AgentA.ps1 to apply correct rules."
