<#
.SYNOPSIS
  Register (or with -Undo remove) the tasks that keep the Windows key vivac's.

.DESCRIPTION
  Run elevated. Two tasks under \vivac\:

    keyguard  at every sign-in, elevated, restarted if it ever stops:
              bin/vivac-keyguard.ps1, which holds the Windows key back where
              the resident host cannot see it (an administrator's window in
              front) and starts the host again when it is not running
    daemon    on demand only, at the normal level: bin/vivac-daemon.ps1, the
              way GlazeWM starts it, for the key guard to start it with

  Neither replaces GlazeWM starting the host at sign-in; the host refuses a
  second copy of itself, so starting it twice is harmless.
#>
[CmdletBinding()]
param([switch]$Undo)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$user = "$env:USERDOMAIN\$env:USERNAME"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'register-keyguard: run this from an elevated PowerShell'
}

if ($Undo) {
    foreach ($name in 'keyguard', 'daemon') {
        Get-ScheduledTask -TaskPath '\vivac\' -TaskName $name -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath '\vivac\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        "removed: \vivac\$name"
    }
    return
}

$ps = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable

# The guard runs elevated without a prompt, so what it runs is a copy only
# administrators can change (lib/Protected.psm1), not the repository's.
Import-Module (Join-Path $root 'lib\Protected.psm1') -Force
Initialize-VivacDataRoot $user
$guarded = Install-VivacProtectedFiles $root @('bin\vivac-keyguard.ps1', 'lib\Vivac.psm1') 'keyguard'
$guard = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $ps `"$guarded\bin\vivac-keyguard.ps1`""
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$high = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'keyguard' -Action $guard -Trigger $atLogon -Principal $high -Settings $settings -Force | Out-Null
'registered: \vivac\keyguard (at sign-in, elevated)'

$daemon = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $root\bin\vivac-daemon.ps1"
$normal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive
Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'daemon' -Action $daemon -Principal $normal -Settings $settings -Force | Out-Null
'registered: \vivac\daemon (on demand, normal level)'

Start-ScheduledTask -TaskPath '\vivac\' -TaskName 'keyguard'
'started: \vivac\keyguard'
