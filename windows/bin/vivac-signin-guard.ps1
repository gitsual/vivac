<#
.SYNOPSIS
  First thing at sign-in: open the desktop after a switch from Linux, lock
  it with Windows' own lock otherwise.

.DESCRIPTION
  With automatic sign-in (apply-system.ps1 -AutoLogin) Windows opens the
  session by itself. This makes the session closed by default, without
  depending on vivac's greeter: unless Restart in Windows left a fresh
  switch token (lib\Switch.psm1), it locks the session at once with
  Windows' own lock (LockWorkStation), which unlocks with the PIN, Hello or
  the password as always. The token is taken away either way.

  It leaves the host (bin\vivac-daemon.ps1 -LockAtStart) a marker saying
  what it did, so the host does not add its greeter on top. Kept small and
  free of vivac's other modules: the shorter its start, the shorter the
  session stays open.

    (none)       do it (what the task runs)
    -Register    register \vivac\signin-guard: at sign-in, this user, normal
                 level, high priority
    -Unregister  remove it
#>
[CmdletBinding()]
param([switch]$Register, [switch]$Unregister)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Register -or $Unregister) {
    $taskPath = '\vivac\'; $taskName = 'signin-guard'
    # The host takes the switch token itself only while this flag is absent:
    # with the guard installed, the token is the guard's alone.
    $local = $env:VIVAC_LOCALAPPDATA
    if (-not $local) { $local = $env:LOCALAPPDATA }
    $installed = Join-Path (Join-Path $local 'vivac') 'signin-guard.installed'
    if ($Unregister) {
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $installed -Force -ErrorAction SilentlyContinue
        "removed: $taskPath$taskName"
        return
    }
    # Normal level, like every task that runs a file the user can write; the
    # lock it calls needs no more.
    # The token's own name: USERDOMAIN is not always set (an SSH session).
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -Priority 1
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $set -Force | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installed) | Out-Null
    Set-Content -LiteralPath $installed -Value $PSCommandPath -Encoding ASCII
    "registered: $taskPath$taskName (at sign-in, normal level, runs $PSCommandPath)"
    return
}

$local = $env:VIVAC_LOCALAPPDATA
if (-not $local) { $local = $env:LOCALAPPDATA }
$state = Join-Path $local 'vivac'
$switched = $false
try {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Switch.psm1') -Force
    $switched = Use-VivacSwitchArrival (Join-Path $state 'switch-arrival')
} catch { }

if ($switched) {
    try { Write-VivacSigninMarker (Join-Path $state 'signin-guard') 'switch' } catch { }
    return
}
# Closed by default: whatever went wrong above, the lock still comes.
$lock = $env:VIVAC_SIGNIN_LOCK
if ($lock) { & $lock } else { & rundll32.exe user32.dll, LockWorkStation }
try { Write-VivacSigninMarker (Join-Path $state 'signin-guard') 'locked' } catch { }
