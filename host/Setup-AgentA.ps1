<#
.SYNOPSIS
  One-shot AgentA setup: prereq check -> auto-fix -> install.
.DESCRIPTION
  Self-elevates via UAC. Runs Check-Prereqs.ps1; if any FAIL remains after
  -Fix attempt, aborts. Otherwise invokes Install-AgentA.ps1.

  Reboots: if optional features are newly enabled, the script will prompt
  to reboot and re-run after restart (Install-AgentA needs the features active).

.PARAMETER SkipFix
  Skip the -Fix pass (still runs prereq check + install).
.PARAMETER DryRun
  Run prereq check only, do not install.
#>
[CmdletBinding()]
param(
    [switch]$SkipFix,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Self-elevate
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) {
    Write-Output "Not elevated. Relaunching via UAC..."
    $argList = @('-NoExit','-ExecutionPolicy','Bypass','-NoProfile','-File',$PSCommandPath)
    if ($SkipFix) { $argList += '-SkipFix' }
    if ($DryRun)  { $argList += '-DryRun' }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit 0
}

$root = Split-Path $PSScriptRoot
$check = Join-Path $PSScriptRoot "Check-Prereqs.ps1"
$install = Join-Path $PSScriptRoot "Install-AgentA.ps1"

Write-Output ""
Write-Output "========================================"
Write-Output "AgentA Setup - elevated session"
Write-Output "========================================"
Write-Output ""

function Get-PrereqFails {
    param([switch]$Fix)
    # Capture Check-Prereqs output as string so we can parse the fail count
    # robustly (more reliable than $global:LASTPREREQFAILS across script invocations).
    $checkArgs = @()
    if ($Fix) { $checkArgs += '-Fix' }
    $out = & $check @checkArgs 2>&1 | Out-String
    Write-Output $out
    $m = [regex]::Match($out, '(?m)^(\d+) FAIL')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

# Pass 1: probe
Write-Output "[1/3] Probe prerequisites..."
$preFails = Get-PrereqFails

if ($preFails -gt 0 -and -not $SkipFix) {
    Write-Output ""
    Write-Output "[2/3] Auto-fix missing optional features..."
    $postFails = Get-PrereqFails -Fix

    if ($postFails -gt 0) {
        Write-Output ""
        Write-Output "Still $postFails FAIL after -Fix. Cannot proceed. See messages above."
        Read-Host "Press Enter to close"
        exit 1
    }

    # If features were newly enabled, reboot is required
    $needsReboot = $false
    try {
        $hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
        $sbox = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
        if ($hyperv.RestartNeeded -or $sbox.RestartNeeded) { $needsReboot = $true }
    } catch {}

    if ($needsReboot) {
        Write-Output ""
        Write-Output "Reboot required for newly-enabled features."
        $ans = Read-Host "Reboot now and re-run setup after restart? [y/N]"
        if ($ans -match '^[Yy]') {
            # Schedule re-run via RunOnce
            $cmd = "powershell -ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name AgentA-Setup -Value $cmd
            Restart-Computer -Force
        } else {
            Write-Output "Reboot manually then re-run: $PSCommandPath"
            Read-Host "Press Enter to close"
            exit 0
        }
    }
} elseif ($preFails -gt 0) {
    Write-Output ""
    Write-Output "$preFails FAIL and -SkipFix was set. Cannot proceed."
    Read-Host "Press Enter to close"
    exit 1
}

if ($DryRun) {
    Write-Output ""
    Write-Output "-DryRun set, skipping install."
    Read-Host "Press Enter to close"
    exit 0
}

# Pass 2: install
Write-Output ""
Write-Output "[3/3] Run Install-AgentA.ps1..."
Write-Output ""
& $install -Root $root

Write-Output ""
Write-Output "========================================"
Write-Output "Setup complete."
Write-Output "========================================"
Write-Output "Next steps:"
Write-Output "  1. Copy .claude\settings.local.json.example to .claude\settings.local.json"
Write-Output "  2. Fill in HEALTHCHECKS_URL, REPORT_EMAIL_TO, SMTP_HOST"
Write-Output "  3. Open Claude Code in $root and try /orchestrate example-task"
Write-Output ""
Read-Host "Press Enter to close"
