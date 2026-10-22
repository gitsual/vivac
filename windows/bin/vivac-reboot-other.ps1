<#
.SYNOPSIS
  Restart into Linux, once: the next boot goes to the Linux loader, the one
  after it is the firmware's usual.

.DESCRIPTION
  The Windows side of docs/bridge.md, "Reboot into the other system". It sets
  the UEFI BootNext variable (bcdedit's {fwbootmgr} bootsequence) to the
  firmware entry of the Linux loader and restarts. GRUB's default and the
  firmware's boot order are not changed.

    (none)       ask for it: start the task \vivac\reboot-other, or, without
                 it, run -Run behind a UAC prompt
    -DryRun      name the entry it would choose; change nothing (reading the
                 firmware entries needs an elevated PowerShell)
    -Run         set BootNext and restart (elevated; what the task runs)
    -Register    register \vivac\reboot-other: on demand, elevated, running a
                 protected copy under C:\Program Files\vivac (elevated)
    -Unregister  remove it (elevated)

  The entry is the first whose description names a Linux loader (GRUB, Arch,
  Linux, vivac, systemd-boot, rEFInd), never Windows Boot Manager.
#>
[CmdletBinding()]
param([switch]$DryRun, [switch]$Run, [switch]$Register, [switch]$Unregister)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\BootNext.psm1') -Force
$taskPath = '\vivac\'
$taskName = 'reboot-other'

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The Linux entry, read from the firmware. Throws with the reason when there
# is none.
function Get-LinuxEntry {
    $lines = @(& bcdedit.exe /enum firmware 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /enum firmware failed: $($lines -join ' ')" }
    $entry = Select-VivacLinuxEntry (ConvertFrom-VivacFirmwareList $lines)
    if (-not $entry) { throw 'no firmware entry names a Linux loader (GRUB, Arch, Linux, vivac, systemd-boot, rEFInd)' }
    $entry
}

if ($Register -or $Unregister) {
    Import-Module (Join-Path $root 'lib\Protected.psm1') -Force
    if (-not (Test-Elevated)) { throw 'vivac-reboot-other: -Register and -Unregister need an elevated PowerShell' }
    if ($Unregister) {
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        "removed: $taskPath$taskName"
        return
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $dest = Install-VivacProtectedFiles $root @('bin\vivac-reboot-other.ps1', 'lib\BootNext.psm1') 'reboot-other'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\bin\vivac-reboot-other.ps1`" -Run"
    $high = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Principal $high -Settings $settings -Force | Out-Null
    "registered: $taskPath$taskName (on demand, elevated, runs $dest\bin\vivac-reboot-other.ps1)"
    return
}

if ($DryRun) {
    if (-not (Test-Elevated)) { 'reading the firmware entries needs an elevated PowerShell: run this again from one'; return }
    $e = Get-LinuxEntry
    "would boot once into: $($e.Description) $($e.Id)"
    return
}

if ($Run) {
    if (-not (Test-Elevated)) { throw 'vivac-reboot-other: -Run needs an elevated PowerShell' }
    $e = Get-LinuxEntry
    $out = & bcdedit.exe /set '{fwbootmgr}' bootsequence $e.Id 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /set bootsequence failed: $out" }
    & shutdown.exe /r /t 0
    return
}

# Asked from the power menu or a terminal: the task when it is there (no
# prompt), a UAC prompt otherwise.
if (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
} else {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Run')
}
