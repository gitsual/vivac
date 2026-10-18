<#
.SYNOPSIS
  Register (or with -Undo remove) the task that runs winget elevated.

.DESCRIPTION
  Run elevated, once. The task \vivac\winget runs on demand only, elevated, as
  this user: bin/vivac-winget.ps1 -Run, which takes the install and update
  requests bin/vivac-winget.ps1 -Queue leaves for it. Starting it needs no
  elevation, so installing and updating from the bar or a terminal no
  longer stops at a UAC prompt.
#>
[CmdletBinding()]
param([switch]$Undo)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$user = "$env:USERDOMAIN\$env:USERNAME"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'register-winget: run this from an elevated PowerShell'
}

if ($Undo) {
    Unregister-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -Confirm:$false -ErrorAction SilentlyContinue
    'removed: \vivac\winget'
    return
}

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
    -MultipleInstances IgnoreNew -StartWhenAvailable
$run = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $root\bin\vivac-winget.ps1 -Run"
$high = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -Action $run -Principal $high -Settings $settings -Force | Out-Null
'registered: \vivac\winget (on demand, elevated)'
