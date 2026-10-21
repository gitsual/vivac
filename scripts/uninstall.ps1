<#
.SYNOPSIS
  Undo vivac: put back what was there before.

.DESCRIPTION
  For every file in the deploy manifest: if a backup of it exists, the oldest
  one (the file as it was before vivac ever touched it) is restored; if not,
  and the file is still exactly what vivac wrote, it is removed; if it was
  edited after the deploy, it is left where it is and reported. Then the
  Windows values saved before the first deploy (wallpaper, accent, dark mode)
  and before each system profile are restored.

  The backups themselves are kept: undoing an undo stays possible.

.PARAMETER DryRun
  Say what would be restored or removed, and change nothing.
#>
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Deploy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Desktop.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$paths = Get-VivacPaths
$manifest = Read-VivacManifest
$stamps = @()
if (Test-Path -LiteralPath $paths.Backups) { $stamps = @(Get-ChildItem -LiteralPath $paths.Backups -Directory | Sort-Object Name | ForEach-Object { $_.FullName }) }

foreach ($target in ($manifest.Keys | Sort-Object)) {
    $safe = $target -replace '^[A-Za-z]:\\', ''
    $backup = $null
    foreach ($s in $stamps) {
        $candidate = Join-Path $s $safe
        if (Test-Path -LiteralPath $candidate) { $backup = $candidate; break }
    }
    $exists = Test-Path -LiteralPath $target
    if ($backup) {
        Write-Host "  [restore]   $target"
        if (-not $DryRun) { Copy-Item -LiteralPath $backup -Destination $target -Force }
    } elseif ($exists -and (Get-VivacHash $target) -eq $manifest[$target].Hash) {
        Write-Host "  [remove]    $target"
        if (-not $DryRun) { Remove-Item -LiteralPath $target -Force }
    } elseif ($exists) {
        Write-Warning (T 'deploy.kept_edited' @($target))
    }
}
if (-not $DryRun -and (Test-Path -LiteralPath $paths.Manifest)) { Remove-Item -LiteralPath $paths.Manifest -Force }

Write-Host (T 'uninstall.desktop')
if (-not $DryRun) { [void](Restore-VivacWindowsOriginal) }

# System profiles: only the ones that were applied have a saved original.
$sys = Join-Path $paths.State 'system-original.json'
if (Test-Path -LiteralPath $sys) {
    $o = Get-Content -Raw -LiteralPath $sys | ConvertFrom-Json
    $has = { param($n) [bool]$o.PSObject.Properties[$n] }
    if (& $has 'toasts') {
        Write-Host '  [restore]   notification banners'
        Import-Module (Join-Path $PSScriptRoot '..\lib\Toasts.psm1') -Force
        [void](Restore-VivacToastBanners -DryRun:$DryRun)
    }
    if (& $has 'run_glazewm') {
        Write-Host '  [restore]   HKCU Run\GlazeWM, task \vivac\bar-watch'
        if (-not $DryRun) {
            [void](& (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-bar-watch.ps1') -Unregister)
            $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if ($o.run_glazewm) { Set-ItemProperty -LiteralPath $run -Name GlazeWM -Value $o.run_glazewm } else { Remove-ItemProperty -LiteralPath $run -Name GlazeWM -ErrorAction SilentlyContinue }
        }
    }
    if (& $has 'screensaver') {
        Write-Host '  [restore]   screen saver / lock timeout'
        if (-not $DryRun) {
            foreach ($p in $o.screensaver.PSObject.Properties) {
                if ($null -eq $p.Value) { Remove-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name $p.Name -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name $p.Name -Value $p.Value }
            }
        }
    }
    foreach ($pair in @(@('power_video', 'SUB_VIDEO', 'VIDEOIDLE'), @('power_sleep', 'SUB_SLEEP', 'STANDBYIDLE'))) {
        if ((& $has $pair[0]) -and $o.($pair[0])) {
            Write-Host "  [restore]   powercfg $($pair[2])"
            if (-not $DryRun) {
                & powercfg /setacvalueindex SCHEME_CURRENT $pair[1] $pair[2] $o.($pair[0])[0]
                & powercfg /setdcvalueindex SCHEME_CURRENT $pair[1] $pair[2] $o.($pair[0])[1]
                & powercfg /setactive SCHEME_CURRENT
            }
        }
    }
    $restartExplorer = $false
    if (& $has 'taskbar_settings') {
        Write-Host '  [restore]   taskbar'
        if (-not $DryRun) {
            # The marker first, so a resident host still running stops hiding it.
            Remove-Item -LiteralPath (Join-Path $paths.State 'hide-taskbar') -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' -Name Settings -Value ([Convert]::FromBase64String($o.taskbar_settings)) -Type Binary
            $restartExplorer = $true
        }
    }
    if (& $has 'hide_icons') {
        Write-Host '  [restore]   desktop icons, task \vivac\tidy-desktop'
        if (-not $DryRun) {
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            if ($null -eq $o.hide_icons) { Remove-ItemProperty -LiteralPath $adv -Name HideIcons -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -LiteralPath $adv -Name HideIcons -Value ([int]$o.hide_icons) -Type DWord }
            $restartExplorer = $true
            [void](& (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-tidy-desktop.ps1') -Unregister)
        }
    }
    if (& $has 'disabled_hotkeys') {
        Write-Host '  [restore]   Win+R for Explorer'
        if (-not $DryRun) {
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            if ($null -eq $o.disabled_hotkeys) { Remove-ItemProperty -LiteralPath $adv -Name DisabledHotkeys -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -LiteralPath $adv -Name DisabledHotkeys -Value ([string]$o.disabled_hotkeys) -Type String }
            $restartExplorer = $true
        }
    }
    # A restarted Explorer shows the taskbar windows anew, which undoes the
    # host's hiding as well.
    if ($restartExplorer) {
        Stop-Process -Name explorer -Force
        Start-Sleep -Seconds 2
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    }
    # Automatic sign-in goes first and is undone whenever this runs elevated:
    # it is the one profile that leaves the machine weaker than it found it.
    if (& $has 'autologin') {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) {
            Write-Host '  [restore]   automatic sign-in off, Windows Hello setting, task \vivac\lock-at-signin'
            if (-not $DryRun) {
                $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                & (Join-Path $PSScriptRoot 'set-autologon.ps1') -Disable
                $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
                if ($null -eq $o.autologin.DevicePasswordLessBuildVersion) { Remove-ItemProperty -LiteralPath $pl -Name DevicePasswordLessBuildVersion -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -LiteralPath $pl -Name DevicePasswordLessBuildVersion -Value ([int]$o.autologin.DevicePasswordLessBuildVersion) -Type DWord }
                Unregister-ScheduledTask -TaskPath '\vivac\' -TaskName 'lock-at-signin' -Confirm:$false -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warning 'automatic sign-in is on: run scripts\uninstall.ps1 from an elevated PowerShell to turn it off'
        }
    }
    # The boot menu and logo: vivac's files off the EFI partition (custom.cfg
    # back to what it was, if anything), the task and the sync script.
    if (& $has 'boot') {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) {
            Write-Host '  [restore]   GRUB theme, \grub\custom.cfg, HackBGRT, task \vivac\boot-sync'
            if (-not $DryRun) {
                Unregister-ScheduledTask -TaskPath '\vivac\' -TaskName 'boot-sync' -Confirm:$false -ErrorAction SilentlyContinue
                Import-Module (Join-Path $PSScriptRoot '..\lib\Boot.psm1') -Force
                $esp = Mount-VivacEsp
                if ($esp) {
                    try {
                        Remove-Item -LiteralPath (Join-Path $esp 'grub\themes\vivac') -Recurse -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath (Join-Path $esp 'EFI\HackBGRT') -Recurse -Force -ErrorAction SilentlyContinue
                        $cfg = Join-Path $esp 'grub\custom.cfg'
                        if ($o.boot.custom_cfg) { [IO.File]::WriteAllText($cfg, [string]$o.boot.custom_cfg) }
                        else { Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue }
                    } finally { Dismount-VivacEsp $esp }
                }
                Remove-Item -LiteralPath (Join-Path $env:ProgramFiles 'vivac') -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $env:ProgramData 'vivac\boot-stage') -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warning 'the boot menu and logo are vivac''s: run scripts\uninstall.ps1 from an elevated PowerShell to remove them'
        }
    }    $machine = @('firewall', 'defender', 'security_quiet', 'lockscreen', 'lockscreen_acrylic') | Where-Object { & $has $_ }
    if ($machine) { Write-Host (T 'uninstall.machine_profiles' @(($machine -join ', '), $sys)) }
    if (-not $DryRun -and -not $machine) { Remove-Item -LiteralPath $sys -Force }
}
Write-Host (T 'uninstall.done')
