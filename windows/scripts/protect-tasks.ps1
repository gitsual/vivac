<#
.SYNOPSIS
  Make every task that runs elevated without a prompt run only files that
  administrators alone can change. Run elevated; again after updating vivac.

.DESCRIPTION
  A task registered to run elevated ("highest privileges") starts without a
  UAC prompt. If the file it runs is one the user can write without
  elevation -- anything under the user's folders, this repository included --
  any program running as the user can edit it and have it run as
  administrator: UAC undone. This script:

    - makes C:\ProgramData\vivac (logs, the winget queue) with permissions of
      its own (lib/Protected.psm1)
    - \vivac\winget, \vivac\keyguard: copies what they run into
      C:\Program Files\vivac and registers them there
      (scripts/register-winget.ps1, scripts/register-keyguard.ps1)
    - \dualboot\mount-m2: the same, for the shared disk's mount script
    - \vivac\lock-at-signin: back to the normal level (it needs no elevation)
    - then checks every elevated task outside \Microsoft\ and fails if one
      still runs a file the user could change

  -Check only reports, needs no elevation, and changes nothing: which
  protected copies differ from the repository (vivac was updated since).
  -Audit only runs the final check, also without elevation.
#>
[CmdletBinding()]
param([switch]$Check, [switch]$Audit)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Protected.psm1') -Force
$user = "$env:USERDOMAIN\$env:USERNAME"
$dualboot = Join-Path $env:USERPROFILE 'dualboot'

$sets = @(
    @{ Into = 'winget'; Root = $root; Files = @('bin\vivac-winget.ps1') },
    @{ Into = 'keyguard'; Root = $root; Files = @('bin\vivac-keyguard.ps1', 'lib\Vivac.psm1') },
    @{ Into = 'reboot-other'; Root = $root; Files = @('bin\vivac-reboot-other.ps1', 'lib\BootNext.psm1') },
    @{ Into = 'dualboot'; Root = $dualboot; Files = @('mount-m2.ps1') }
)

if ($Check) {
    foreach ($s in $sets) {
        if (-not (Test-Path -LiteralPath $s.Root)) { continue }
        foreach ($f in @(Get-VivacProtectedDrift $s.Root $s.Files $s.Into)) { "stale: $($s.Into)\$f (run scripts\protect-tasks.ps1 elevated)" }
    }
    return
}

if (-not $Audit) {
if (-not (Test-VivacElevated)) { throw 'protect-tasks: run this from an elevated PowerShell' }

Initialize-VivacDataRoot $user
'ProgramData\vivac: logs and the winget queue, administrators only (the inbox: the user may add files)'

if (Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -ErrorAction SilentlyContinue) {
    & (Join-Path $PSScriptRoot 'register-winget.ps1')
}
if (Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'reboot-other' -ErrorAction SilentlyContinue) {
    & (Join-Path $root 'bin\vivac-reboot-other.ps1') -Register
}
$guard = Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'keyguard' -ErrorAction SilentlyContinue
if ($guard) {
    # The copy running now is the repository's: stopped, so the protected one
    # takes over.
    $guard | Stop-ScheduledTask -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'vivac-keyguard\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    & (Join-Path $PSScriptRoot 'register-keyguard.ps1')
}
$mount = Get-ScheduledTask -TaskPath '\dualboot\' -TaskName 'mount-m2' -ErrorAction SilentlyContinue
if ($mount -and (Test-Path -LiteralPath (Join-Path $dualboot 'mount-m2.ps1'))) {
    $dest = Install-VivacProtectedFiles $dualboot @('mount-m2.ps1') 'dualboot'
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\mount-m2.ps1`""
    Set-ScheduledTask -TaskPath '\dualboot\' -TaskName 'mount-m2' -Action $a | Out-Null
    "registered: \dualboot\mount-m2 (at sign-in, elevated, runs $dest\mount-m2.ps1)"
}
$lock = Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'lock-at-signin' -ErrorAction SilentlyContinue
if ($lock) {
    $p = New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive
    Set-ScheduledTask -TaskPath '\vivac\' -TaskName 'lock-at-signin' -Principal $p | Out-Null
    'registered: \vivac\lock-at-signin (at sign-in, normal level)'
}
}

# The audit: every elevated task outside Microsoft's own, and whether the user
# could change what it runs.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$bad = @()
foreach ($t in Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.Principal.RunLevel -eq 'Highest' }) {
    foreach ($a in $t.Actions) {
        $target = [Environment]::ExpandEnvironmentVariables([string]$a.Execute)
        if ([string]$a.Arguments -match '-File\s+"?([^"]+\.ps1)') { $target = $Matches[1] }
        if (-not (Test-Path -LiteralPath $target)) {
            $cmd = Get-Command $target -ErrorAction SilentlyContinue | Select-Object -First 1
            $target = if ($cmd -and $cmd.PSObject.Properties['Source']) { $cmd.Source } else { $null }
        }
        if (-not $target -or -not (Test-Path -LiteralPath $target)) { continue }
        $writable = (Get-Acl -LiteralPath $target).Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights -match 'Write|Modify|FullControl|ChangePermissions|TakeOwnership' -and
            ($_.IdentityReference.Value -match "\\$([regex]::Escape($env:USERNAME))$|^(Todos|Everyone|BUILTIN\\(Usuarios|Users)|NT AUTHORITY\\(Usuarios autentificados|Authenticated Users))$")
        }
        $state = if ($writable) { 'USER-WRITABLE'; $bad += "$($t.TaskPath)$($t.TaskName)" } else { 'ok' }
        "{0,-14} {1}{2} -> {3}" -f $state, $t.TaskPath, $t.TaskName, $target
    }
}
if ($bad.Count) { throw "protect-tasks: still running a file the user can change: $($bad -join ', ')" }
'every elevated task runs files only administrators can change'
