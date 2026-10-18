<#
.SYNOPSIS
  Register (or with -Undo remove) the task that updates programs with winget
  elevated.

.DESCRIPTION
  Run elevated, once, and again after updating vivac (scripts/protect-tasks.ps1
  does both). The task \vivac\winget runs on demand only, elevated, as this
  user: a copy of bin/vivac-winget.ps1 in C:\Program Files\vivac\winget, with
  -Run, which takes the update requests bin/vivac-winget.ps1 -Queue leaves in
  C:\ProgramData\vivac\winget\inbox. Starting it needs no elevation, so
  updating from the bar or a terminal no longer stops at a UAC prompt; what it
  runs cannot be changed without one (lib/Protected.psm1).
#>
[CmdletBinding()]
param([switch]$Undo)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Protected.psm1') -Force
$user = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-VivacElevated)) { throw 'register-winget: run this from an elevated PowerShell' }

if ($Undo) {
    Unregister-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -Confirm:$false -ErrorAction SilentlyContinue
    'removed: \vivac\winget'
    return
}

Initialize-VivacDataRoot $user
$dest = Install-VivacProtectedFiles $root @('bin\vivac-winget.ps1') 'winget'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
    -MultipleInstances IgnoreNew -StartWhenAvailable
$run = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\bin\vivac-winget.ps1`" -Run"
$high = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -Action $run -Principal $high -Settings $settings -Force | Out-Null
"registered: \vivac\winget (on demand, elevated, runs $dest\bin\vivac-winget.ps1)"
