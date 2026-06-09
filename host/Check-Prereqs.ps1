<#
.SYNOPSIS
  Verify AgentA prerequisites. Run as Administrator for full coverage.
.PARAMETER Fix
  Attempt to enable missing optional features. Requires Administrator + reboot.
#>
[CmdletBinding()]
param([switch]$Fix)

$ErrorActionPreference = "Continue"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

$results = @()
function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail, [string]$FixHint = "")
    $script:results += [pscustomobject]@{
        Check    = $Check
        Status   = $Status
        Detail   = $Detail
        FixHint  = $FixHint
    }
}

# 1. Admin
if ($isAdmin) {
    Add-Result "Administrator"  "OK"   "elevated session"
} else {
    Add-Result "Administrator"  "FAIL" "not elevated"  "re-run from elevated PowerShell"
}

# 2. Windows edition
try {
    $edition = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($edition -match "Pro|Enterprise|Education") {
        Add-Result "Windows Edition"  "OK"  $edition
    } else {
        Add-Result "Windows Edition"  "FAIL"  "$edition needs Pro/Enterprise/Education"  "upgrade Windows edition"
    }
} catch {
    Add-Result "Windows Edition"  "WARN"  "query failed"
}

# 3. PowerShell version
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) {
    Add-Result "PowerShell"  "OK"  "$psv"
} else {
    Add-Result "PowerShell"  "FAIL"  "$psv need 5.1 or newer"  "install Windows Management Framework 5.1"
}

# 4. CPU virtualization
# WMI Win32_Processor flips VirtualizationFirmwareEnabled=False when Hyper-V is the
# host hypervisor (host OS runs as own guest). Fall back to systeminfo which reports
# "A hypervisor has been detected" in that case.
try {
    $cpu = Get-CimInstance Win32_Processor
    $vt = $cpu.VirtualizationFirmwareEnabled
    $slat = $cpu.SecondLevelAddressTranslationExtensions
    if ($vt -and $slat) {
        Add-Result "CPU Virtualization"  "OK"  "VT-x + SLAT enabled (WMI)"
    } else {
        $sysinfo = (systeminfo) -join "`n"
        if ($sysinfo -match "hypervisor has been detected") {
            Add-Result "CPU Virtualization"  "OK"  "hypervisor active (Hyper-V host)"
        } else {
            Add-Result "CPU Virtualization"  "FAIL"  "VT-x=$vt SLAT=$slat"  "enable VT-x or AMD-V in BIOS/UEFI"
        }
    }
} catch {
    Add-Result "CPU Virtualization"  "WARN"  "could not query"
}

# 5. Hyper-V optional feature
if ($isAdmin) {
    try {
        $hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
        if ($hyperv.State -eq "Enabled") {
            Add-Result "Hyper-V"  "OK"  "enabled"
        } else {
            Add-Result "Hyper-V"  "FAIL"  $hyperv.State  "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
            if ($Fix) {
                Write-Output "  Enabling Hyper-V (reboot required after)..."
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
            }
        }
    } catch {
        Add-Result "Hyper-V"  "WARN"  "query failed"
    }
} else {
    Add-Result "Hyper-V"  "SKIP"  "needs admin to query"
}

# 6. Windows Sandbox optional feature
if ($isAdmin) {
    try {
        $sbox = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -ErrorAction Stop
        if ($sbox.State -eq "Enabled") {
            Add-Result "Windows Sandbox"  "OK"  "enabled"
        } else {
            Add-Result "Windows Sandbox"  "FAIL"  $sbox.State  "Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All"
            if ($Fix) {
                Write-Output "  Enabling Windows Sandbox (reboot required after)..."
                Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart | Out-Null
            }
        }
    } catch {
        Add-Result "Windows Sandbox"  "WARN"  "query failed"
    }
} else {
    Add-Result "Windows Sandbox"  "SKIP"  "needs admin to query"
}

# 7. BitLocker service
try {
    $bl = Get-Service -Name BDESVC -ErrorAction Stop
    Add-Result "BitLocker Service"  "OK"  "$($bl.Status)"
} catch {
    Add-Result "BitLocker Service"  "FAIL"  "BDESVC not available"  "install BitLocker feature"
}

# 8. Git
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $gitVer = (& git --version) -replace "git version ",""
    Add-Result "Git"  "OK"  "$gitVer"
} else {
    Add-Result "Git"  "FAIL"  "not on PATH"  "winget install Git.Git"
}

# 9. Python
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $pyVer = (& python --version 2>&1) -replace "Python ",""
    Add-Result "Python"  "OK"  "$pyVer"
} else {
    Add-Result "Python"  "WARN"  "not on PATH"  "winget install Python.Python.3.12"
}

# 10. BurntToast
$bt = Get-Module -ListAvailable -Name BurntToast
if ($bt) {
    Add-Result "BurntToast"  "OK"  "$($bt.Version)"
} else {
    Add-Result "BurntToast"  "WARN"  "not installed"  "Install-Module BurntToast -Scope CurrentUser (optional)"
}

# 11. Disk space
$drive = (Get-PSDrive C).Free / 1GB
if ($drive -ge 5) {
    Add-Result "Disk Space (C:)"  "OK"  ("{0:N1} GB free" -f $drive)
} else {
    Add-Result "Disk Space (C:)"  "WARN"  ("{0:N1} GB free need 5 GB" -f $drive)
}

# 12. Claude Code on PATH
$cc = Get-Command claude -ErrorAction SilentlyContinue
if ($cc) {
    Add-Result "Claude Code"  "OK"  "$($cc.Source)"
} else {
    Add-Result "Claude Code"  "WARN"  "claude not on PATH"  "install Claude Code inside sandbox base image or adjust .wsb"
}

# Render
Write-Output ""
Write-Output "AgentA Prerequisite Check"
Write-Output ("=" * 60)
$results | Format-Table Check, Status, Detail -AutoSize | Out-String | Write-Output

$fails = ($results | Where-Object Status -eq "FAIL").Count
$warns = ($results | Where-Object Status -eq "WARN").Count

if ($fails -gt 0) {
    Write-Output "$fails FAIL - must fix before running Install-AgentA.ps1:"
    $results | Where-Object Status -eq "FAIL" | ForEach-Object {
        Write-Output ("  {0}: {1}" -f $_.Check, $_.FixHint)
    }
}
if ($warns -gt 0) {
    Write-Output "$warns WARN - non-blocking but review:"
    $results | Where-Object Status -eq "WARN" | ForEach-Object {
        if ($_.FixHint) { Write-Output ("  {0}: {1}" -f $_.Check, $_.FixHint) }
    }
}
if ($fails -eq 0 -and $warns -eq 0) {
    Write-Output "All checks passed. Ready to run Install-AgentA.ps1"
}

if ($Fix -and -not $isAdmin) {
    Write-Output "-Fix requested but session not elevated, no changes applied."
}
if ($Fix -and $isAdmin -and ($fails -gt 0 -or $warns -gt 0)) {
    Write-Output "Reboot required for any newly-enabled optional features."
}

$global:LASTPREREQFAILS = $fails
