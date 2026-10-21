<#
.SYNOPSIS
  Opt-in system profiles, each with a dry run of its own.

.DESCRIPTION
  Never run by deploy.ps1. Each switch is one profile; nothing happens
  without one. The values found before a profile first changes something are
  saved to %LOCALAPPDATA%\vivac\system-original.json, once.
  scripts/uninstall.ps1 restores the per-user ones; for the machine-wide
  ones it names the saved values, to be put back from an elevated prompt.

  Per user (no elevation):
    -Session    start GlazeWM (and with it the bar) at sign-in
    -Idle       lock after 5 minutes, screen off after 10, sleep after 30
    -Taskbar    no Windows taskbar: auto-hidden, and kept hidden by vivac's
                resident host so it does not slide back in at the screen
                edge; the bar takes its place, with its own pills for what the tray held
    -DesktopIcons  no icons on the desktop (they show through translucent
                terminals and sit under every tiled window anyway), and the
                shortcuts installers leave there moved into the Start menu,
                where the launchers find them (bin/vivac-tidy-desktop.ps1)
    -WinKeys    Explorer gives up Win+R, so the Run box never opens over
                vivac's menu, which the resident host opens on Win+R
    -Toasts     other programs' notifications as vivac's cards at the top
                right; Windows' banners at the bottom right turned off
                (Windows Security keeps its own; lib/Toasts.psm1)

  Machine-wide (run elevated):
    -Firewall   every profile on, unsolicited inbound denied, outbound
                allowed; existing allow rules are kept, no port is opened
    -Defender   potentially unwanted apps blocked, cloud protection on,
                signatures refreshed, a weekly quick scan (the source's
                weekly ClamAV home scan)
    -SecurityQuiet  Windows Security without its tray icon or its
                non-critical notifications: the shield on the bar and the
                security surface show Defender's state instead; threat
                alerts stay
    -LockScreen the theme's wallpaper on the lock screen and the sign-in
                screen, without the sign-in screen's blur
    -Link       vivac link reachable from the local network: TCP and UDP
                47321 in, private networks and the local subnet only
                (docs/bridge.md at the product root)
    -LocalSend  the phone drop reachable from phones with LocalSend: TCP and
                UDP 53317 in, private networks and the local subnet only. A
                rule of its own, apart from -Link: phones are other devices
                than the paired machine, and either may be wanted alone. The
                receiver itself starts only with vivac-localsend.ps1 on
    -Boot       GRUB's menu and the boot logo in the theme, following every
                theme switch: HackBGRT (pinned, checked) and a GRUB theme on
                the EFI partition shared with Arch, carried there by a SYSTEM
                task (scripts\boot-sync.ps1) that this user may start.
                Secure Boot must be off
    -AutoLogin  Windows signs in by itself and vivac's lock is the first thing
                on screen (its host starts at sign-in with -LockAtStart). The
                password is typed by you into Windows' credential prompt and kept
                as an encrypted LSA secret, never in plain text
                (scripts\set-autologon.ps1).
                Weaker against someone with the machine in their hands: for
                the seconds before the host starts, the session is open.

.PARAMETER DryRun
  Say what each chosen profile would change, and change nothing.
#>
[CmdletBinding()]
param(
    [switch]$Session, [switch]$Idle, [switch]$Taskbar, [switch]$DesktopIcons, [switch]$WinKeys, [switch]$Toasts,
    [switch]$Firewall, [switch]$Defender, [switch]$SecurityQuiet, [switch]$LockScreen, [switch]$AutoLogin, [switch]$Boot, [switch]$Link, [switch]$LocalSend,
    [switch]$DryRun
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Apps.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$restartExplorer = $false
if (-not ($Session -or $Idle -or $Taskbar -or $DesktopIcons -or $WinKeys -or $Toasts -or $Firewall -or $Defender -or $SecurityQuiet -or $LockScreen -or $AutoLogin -or $Boot -or $Link -or $LocalSend)) {
    Write-Host (T 'system.none_chosen')
    return
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Firewall -or $Defender -or $SecurityQuiet -or $LockScreen -or $AutoLogin -or $Boot -or $Link -or $LocalSend) -and -not $admin -and -not $DryRun) {
    throw (T 'system.needs_admin')
}

$originalPath = Join-Path (Get-VivacPaths).State 'system-original.json'
$original = [ordered]@{}
if (Test-Path -LiteralPath $originalPath) {
    foreach ($p in (Get-Content -Raw -LiteralPath $originalPath | ConvertFrom-Json).PSObject.Properties) { $original[$p.Name] = $p.Value }
}
# Record a value only the first time: a second run must not take the first
# run's result for the original.
function Save-Original([string]$Name, $Value) {
    if ($DryRun -or $original.Contains($Name)) { return }
    $original[$Name] = $Value
    Write-VivacFile -Path $originalPath -Text (($original | ConvertTo-Json -Depth 6) + "`n")
}
function Step([string]$Text) {
    $prefix = '  '
    if ($DryRun) { $prefix = '  ' + (T 'system.would') + ' ' }
    Write-Host "$prefix$Text"
}

# The AC and DC values powercfg reports are the last two hex numbers of its
# output, whatever language the labels around them are in.
function Get-PowerIndex([string]$Sub, [string]$Setting) {
    $hex = @([regex]::Matches((powercfg /q SCHEME_CURRENT $Sub $Setting | Out-String), '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    @([Convert]::ToInt32($hex[-2], 16), [Convert]::ToInt32($hex[-1], 16))
}

if ($Session) {
    Write-Host (T 'system.session')
    $glaze = Find-VivacApp 'glazewm'
    if (-not $glaze) { throw (T 'system.glazewm_missing') }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $prevRun = Get-ItemProperty -LiteralPath $run -Name 'GlazeWM' -ErrorAction SilentlyContinue
    $prevValue = $null
    if ($prevRun) { $prevValue = $prevRun.GlazeWM }
    Save-Original 'run_glazewm' $prevValue
    Step (T 'system.session_step' @($glaze))
    if (-not $DryRun) { Set-ItemProperty -LiteralPath $run -Name 'GlazeWM' -Value "`"$glaze`"" -Type String }
    Step (T 'system.bar_watch_step')
    if (-not $DryRun) { [void](& (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-bar-watch.ps1') -Register) }
}

if ($Idle) {
    Write-Host (T 'system.idle')
    $desk = 'HKCU:\Control Panel\Desktop'
    $cur = Get-ItemProperty -LiteralPath $desk
    $saver = [ordered]@{}
    foreach ($n in 'ScreenSaveActive', 'ScreenSaveTimeOut', 'ScreenSaverIsSecure', 'SCRNSAVE.EXE') {
        $prop = $cur.PSObject.Properties[$n]
        if ($prop) { $saver[$n] = [string]$prop.Value } else { $saver[$n] = $null }
    }
    Save-Original 'screensaver' $saver
    Save-Original 'power_video' (Get-PowerIndex 'SUB_VIDEO' 'VIDEOIDLE')
    Save-Original 'power_sleep' (Get-PowerIndex 'SUB_SLEEP' 'STANDBYIDLE')
    # The source locks at 5 minutes, blanks at 10 and suspends at 30. Windows
    # locks through a secure blank screen saver, which needs no elevation.
    Step (T 'system.idle_lock')
    Step (T 'system.idle_screen')
    Step (T 'system.idle_sleep')
    if (-not $DryRun) {
        Set-ItemProperty -LiteralPath $desk -Name 'ScreenSaveActive' -Value '1'
        Set-ItemProperty -LiteralPath $desk -Name 'ScreenSaveTimeOut' -Value '300'
        Set-ItemProperty -LiteralPath $desk -Name 'ScreenSaverIsSecure' -Value '1'
        Set-ItemProperty -LiteralPath $desk -Name 'SCRNSAVE.EXE' -Value "$env:WINDIR\System32\scrnsave.scr"
        foreach ($a in 'monitor-timeout-ac 10', 'monitor-timeout-dc 10', 'standby-timeout-ac 30', 'standby-timeout-dc 30') {
            $parts = $a -split ' '
            & powercfg /change $parts[0] $parts[1]
        }
    }
}

if ($Taskbar) {
    Write-Host (T 'system.taskbar')
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $settingsBytes = [byte[]](Get-ItemProperty -LiteralPath $key -Name Settings).Settings
    Save-Original 'taskbar_settings' ([Convert]::ToBase64String($settingsBytes))
    Step (T 'system.taskbar_step')
    if (-not $DryRun) {
        # Byte 8 holds the auto-hide flag (3 = hide, 2 = always shown); Explorer
        # reads it at start. Auto-hide alone still slides the taskbar back in
        # at the bottom edge, so the marker below tells the resident host to
        # keep its windows hidden too.
        $settingsBytes[8] = 3
        Set-ItemProperty -LiteralPath $key -Name Settings -Value $settingsBytes -Type Binary
        Write-VivacFile -Path (Join-Path (Get-VivacPaths).State 'hide-taskbar') -Text "1`n"
        $restartExplorer = $true
    }
}

if ($DesktopIcons) {
    Write-Host (T 'system.desktop_icons')
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $prev = (Get-ItemProperty -LiteralPath $adv -Name HideIcons -ErrorAction SilentlyContinue)
    $prevValue = $null
    if ($prev) { $prevValue = [int]$prev.HideIcons }
    Save-Original 'hide_icons' $prevValue
    Step (T 'system.desktop_icons_step')
    if (-not $DryRun) {
        Set-ItemProperty -LiteralPath $adv -Name HideIcons -Value 1 -Type DWord
        $restartExplorer = $true
    }
    # Hidden icons still pile up: installers keep dropping shortcuts there.
    # The tidier moves them into the Start menu, where the launchers look.
    Step (T 'system.desktop_tidy_step')
    if (-not $DryRun) { [void](& (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-tidy-desktop.ps1') -Register) }
}

# Explorer registers Win+R for itself, and a hotkey it holds is answered even
# with the Win key held back by vivac's keyboard hook: the Run box would open
# on top of vivac's menu and take its focus, which closes the menu. Letters in
# DisabledHotkeys are Win+letter shortcuts Explorer does not register.
if ($WinKeys) {
    Write-Host (T 'system.win_keys')
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $prev = (Get-ItemProperty -LiteralPath $adv -Name DisabledHotkeys -ErrorAction SilentlyContinue)
    $prevValue = $null
    if ($prev) { $prevValue = [string]$prev.DisabledHotkeys }
    Save-Original 'disabled_hotkeys' $prevValue
    Step (T 'system.win_keys_step')
    if (-not $DryRun) {
        $keys = [string]$prevValue
        if ($keys -notmatch 'R') { $keys += 'R' }
        Set-ItemProperty -LiteralPath $adv -Name DisabledHotkeys -Value $keys -Type String
        $restartExplorer = $true
    }
}

# Notifications: each program's banner off, its notification still kept by
# Windows, and vivac's resident host drawing it instead. What each program's
# banner switch held is saved by lib/Toasts.psm1 itself (toast-banners.json),
# since programs that notify later are switched by the host as they come.
if ($Toasts) {
    Write-Host (T 'system.toasts')
    Import-Module (Join-Path $PSScriptRoot '..\lib\Toasts.psm1') -Force
    Save-Original 'toasts' $true
    $n = @(Enable-VivacToasts -DryRun:$DryRun).Count
    Step (T 'system.toasts_step' @([string]$n))
}

if ($AutoLogin) {
    Write-Host (T 'system.autologin')
    # Microsoft accounts are kept to Windows Hello sign-in by this switch;
    # automatic sign-in needs it off.
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $plv = Get-ItemProperty -LiteralPath $pl -Name DevicePasswordLessBuildVersion -ErrorAction SilentlyContinue
    $wl = Get-ItemProperty -LiteralPath $winlogon -ErrorAction SilentlyContinue
    $was = [ordered]@{ DevicePasswordLessBuildVersion = $null; AutoAdminLogon = $null }
    if ($plv) { $was.DevicePasswordLessBuildVersion = [int]$plv.DevicePasswordLessBuildVersion }
    if ($wl -and $wl.PSObject.Properties['AutoAdminLogon']) { $was.AutoAdminLogon = [string]$wl.AutoAdminLogon }
    Save-Original 'autologin' $was
    Step (T 'system.autologin_hello')
    Step (T 'system.autologin_task')
    Step (T 'system.autologin_tool')
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $pl)) { New-Item -Path $pl -Force | Out-Null }
        Set-ItemProperty -LiteralPath $pl -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
        # The host, at sign-in, before anything else of vivac: the screens
        # are covered and the lock opens. At the normal level: an elevated
        # task must not run a file the user can write, and everything opened
        # from vivac's menu would inherit the elevation (the key guard,
        # bin/vivac-keyguard.ps1, covers keys meant for elevated windows).
        $daemon = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-daemon.ps1'
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$daemon`" -LockAtStart"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Limited -LogonType Interactive
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 4
        Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'lock-at-signin' -Action $action -Trigger $trigger -Principal $principal -Settings $set -Force | Out-Null
        # The password is yours to type, into Windows' own credential prompt,
        # in a window of its own; scripts\set-autologon.ps1 explains the rest.
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$(Join-Path $PSScriptRoot 'set-autologon.ps1')`""
    }
}
# Explorer reads both settings at start; one restart serves the two profiles.
if ($restartExplorer) {
    Stop-Process -Name explorer -Force
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

if ($Firewall) {
    Write-Host (T 'system.firewall')
    $profiles = @(Get-NetFirewallProfile)
    Save-Original 'firewall' @($profiles | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Enabled = [string]$_.Enabled; In = [string]$_.DefaultInboundAction; Out = [string]$_.DefaultOutboundAction } })
    foreach ($fp in $profiles) {
        Step (T 'system.firewall_step' @($fp.Name, $fp.Enabled, $fp.DefaultInboundAction))
    }
    if (-not $DryRun) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow
    }
}

# vivac link (docs/bridge.md) listens on 47321; the firewall decides who may
# reach it: the local subnet, on private networks, nothing else.
if ($Link) {
    Write-Host (T 'system.link')
    Save-Original 'link' $true
    Step (T 'system.link_step')
    if (-not $DryRun) {
        Remove-NetFirewallRule -DisplayName 'vivac link' -ErrorAction SilentlyContinue
        foreach ($protocol in 'TCP', 'UDP') {
            New-NetFirewallRule -DisplayName 'vivac link' -Group 'vivac' -Direction Inbound -Protocol $protocol -LocalPort 47321 -Profile Private -RemoteAddress LocalSubnet -Action Allow | Out-Null
        }
    }
}

# The phone drop (bin/vivac-localsend.ps1) listens on LocalSend's 53317:
# HTTP on TCP, discovery on UDP. The local subnet, private networks only.
if ($LocalSend) {
    Write-Host (T 'system.localsend')
    Save-Original 'localsend' $true
    Step (T 'system.localsend_step')
    if (-not $DryRun) {
        Remove-NetFirewallRule -DisplayName 'vivac phone drop' -ErrorAction SilentlyContinue
        foreach ($protocol in 'TCP', 'UDP') {
            New-NetFirewallRule -DisplayName 'vivac phone drop' -Group 'vivac' -Direction Inbound -Protocol $protocol -LocalPort 53317 -Profile Private -RemoteAddress LocalSubnet -Action Allow | Out-Null
        }
    }
}

if ($Defender) {
    Write-Host (T 'system.defender')
    $pref = Get-MpPreference
    Save-Original 'defender' ([ordered]@{ PUAProtection = [int]$pref.PUAProtection; MAPSReporting = [int]$pref.MAPSReporting; ScanScheduleDay = [int]$pref.ScanScheduleDay; ScanParameters = [int]$pref.ScanParameters; ScanScheduleTime = [string]$pref.ScanScheduleTime })
    Step (T 'system.defender_pua')
    Step (T 'system.defender_cloud')
    Step (T 'system.defender_weekly')
    Step (T 'system.defender_signatures')
    if (-not $DryRun) {
        Set-MpPreference -PUAProtection Enabled -MAPSReporting Advanced -ScanScheduleDay Sunday -ScanParameters QuickScan -ScanScheduleTime ([TimeSpan]::FromHours(12))
        Update-MpSignature
    }
}

# Windows Security keeps a tray icon and a stream of summaries ("no threats
# found", "your device was scanned"); the bar's shield and the security
# surface carry the same news in the palette. Threat alerts are critical
# notifications, which this policy leaves alone.
if ($SecurityQuiet) {
    Write-Host (T 'system.security_quiet')
    $wdsc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
    $toast = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance'
    $keep = [ordered]@{}
    foreach ($v in @(@("$wdsc\Systray", 'HideSystray'), @("$wdsc\Notifications", 'DisableEnhancedNotifications'), @($toast, 'Enabled'))) {
        $prop = Get-ItemProperty -LiteralPath $v[0] -Name $v[1] -ErrorAction SilentlyContinue
        $value = $null
        if ($prop) { $value = [int]$prop.($v[1]) }
        $keep["$($v[0])|$($v[1])"] = $value
    }
    Save-Original 'security_quiet' $keep
    Step (T 'system.security_quiet_tray')
    Step (T 'system.security_quiet_notifications')
    Step (T 'system.security_quiet_toasts')
    if (-not $DryRun) {
        foreach ($k in "$wdsc\Systray", "$wdsc\Notifications", $toast) {
            if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
        }
        Set-ItemProperty -LiteralPath "$wdsc\Systray" -Name HideSystray -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath "$wdsc\Notifications" -Name DisableEnhancedNotifications -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $toast -Name Enabled -Value 0 -Type DWord
        # The icon's process reads the policy at start; it would otherwise
        # stay in the notification area until the next sign-in.
        Get-Process SecurityHealthSystray -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}

if ($LockScreen) {
    Write-Host (T 'system.lockscreen')
    Import-Module (Join-Path $PSScriptRoot '..\lib\Desktop.psm1') -Force
    $png = Get-VivacWallpaper -Theme (Read-VivacTheme (Read-VivacSettings)['theme']) -DryRun:$DryRun
    $csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    $prev = Get-ItemProperty -LiteralPath $csp -ErrorAction SilentlyContinue
    $prevPath = $null
    if ($prev -and $prev.PSObject.Properties['LockScreenImagePath']) { $prevPath = $prev.LockScreenImagePath }
    Save-Original 'lockscreen' $prevPath
    Step (T 'system.lockscreen_step' @($png))
    Step (T 'system.lockscreen_quiet')
    # Windows' rotating pictures, "fun facts", tips and suggestions on the lock
    # screen: per user, recorded before they are turned off.
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $quiet = 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled'
    $was = [ordered]@{}
    foreach ($n in $quiet) {
        $v = Get-ItemProperty -LiteralPath $cdm -Name $n -ErrorAction SilentlyContinue
        if ($v) { $was[$n] = [int]$v.$n } else { $was[$n] = $null }
    }
    Save-Original 'lockscreen_content' $was
    # The sign-in screen blurs the picture behind its field; without the blur
    # it shows the wallpaper as the desktop does.
    $sysPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $acrylic = Get-ItemProperty -LiteralPath $sysPolicy -Name DisableAcrylicBackgroundOnLogon -ErrorAction SilentlyContinue
    $acrylicWas = $null
    if ($acrylic) { $acrylicWas = [int]$acrylic.DisableAcrylicBackgroundOnLogon }
    Save-Original 'lockscreen_acrylic' $acrylicWas
    Step (T 'system.lockscreen_acrylic')
    if (-not $DryRun) {
        Grant-VivacLockScreenToUser
        [void](Update-VivacLockScreen $png)
        if (-not (Test-Path -LiteralPath $cdm)) { New-Item -Path $cdm -Force | Out-Null }
        foreach ($n in $quiet) { Set-ItemProperty -LiteralPath $cdm -Name $n -Value 0 -Type DWord }
        if (-not (Test-Path -LiteralPath $sysPolicy)) { New-Item -Path $sysPolicy -Force | Out-Null }
        Set-ItemProperty -LiteralPath $sysPolicy -Name DisableAcrylicBackgroundOnLogon -Value 1 -Type DWord
    }
}

# Before Windows: GRUB's menu and the boot logo, in the theme, following
# every theme switch (lib\Boot.psm1 has the why of the split). Writes on the
# EFI system partition it shares with Arch, and only there:
#   \EFI\HackBGRT\        HackBGRT, pinned and checked, plus its config
#   \grub\custom.cfg      read by Arch's grub.cfg (its 41_custom section) on
#                         every boot, so grub-mkconfig on Arch keeps it: it
#                         sets the theme and adds a Windows entry through
#                         HackBGRT. Arch's /etc/default/grub is not touched.
#   \grub\themes\vivac\   written by the sync task
# Neither the firmware's boot order nor Windows' own boot loader changes;
# GRUB's existing Windows entry still starts Windows directly.
if ($Boot) {
    Write-Host (T 'system.boot')
    Import-Module (Join-Path $PSScriptRoot '..\lib\Boot.psm1') -Force
    $hbVersion = '2.6.0'
    $hbUrl = "https://github.com/Metabolix/HackBGRT/releases/download/v$hbVersion/HackBGRT-$hbVersion.zip"
    $hbSha = '6204911D777AC03E514B90126568EF6FAA1D477779B31C536B142DBA92F4A2C0'
    $res = Get-VivacBootResolution
    $installDir = Join-Path $env:ProgramFiles 'vivac'
    Step (T 'system.boot_hackbgrt' @($hbVersion, "$($res[0])x$($res[1])"))
    Step (T 'system.boot_grub')
    Step (T 'system.boot_task' @($installDir))
    if (-not $DryRun) {
        $sb = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction SilentlyContinue
        if ($sb -and $sb.UEFISecureBootEnabled -eq 1) { throw (T 'system.boot_secure_boot') }

        $work = Join-Path ([IO.Path]::GetTempPath()) ('vivac-hackbgrt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $esp = $null
        try {
            $zip = Join-Path $work 'hackbgrt.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $hbUrl -OutFile $zip -UseBasicParsing
            $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if ($got -ne $hbSha) { throw (T 'system.boot_bad_hash' @($got)) }
            Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
            $hbDir = Join-Path $work "HackBGRT-$hbVersion"

            $esp = Mount-VivacEsp
            if (-not $esp) { throw (T 'system.boot_no_esp') }
            $customCfg = Join-Path $esp 'grub\custom.cfg'
            if (-not (Test-Path -LiteralPath (Join-Path $esp 'grub\grub.cfg'))) { throw (T 'system.boot_no_grub') }
            $prevCustom = $null
            if (Test-Path -LiteralPath $customCfg) { $prevCustom = [IO.File]::ReadAllText($customCfg) }
            Save-Original 'boot' ([ordered]@{ custom_cfg = $prevCustom })
            if ($prevCustom -and $prevCustom -notmatch 'vivac') { throw (T 'system.boot_custom_exists' @($customCfg)) }

            # HackBGRT without shim (Secure Boot is off) and without any of
            # its installer's boot entries: GRUB is what starts it.
            $hb = Join-Path $esp 'EFI\HackBGRT'
            New-Item -ItemType Directory -Force -Path $hb | Out-Null
            Copy-Item -LiteralPath (Join-Path $hbDir 'efi-signed\bootx64.efi') -Destination (Join-Path $hb 'loader.efi') -Force
            if (-not (Test-Path -LiteralPath (Join-Path $hb 'splash.bmp'))) { Copy-Item -LiteralPath (Join-Path $hbDir 'splash.bmp') -Destination (Join-Path $hb 'splash.bmp') }
            $config = @(
                '# vivac: written by scripts\apply-system.ps1 -Boot. The picture is the',
                '# whole screen, so it is centred; boot-sync.ps1 redraws it per theme.',
                'boot=\EFI\Microsoft\Boot\bootmgfw.efi',
                'image= x=0 y=0 path=splash.bmp',
                "resolution=$($res[0])x$($res[1])",
                'log=1',
                'debug=0'
            )
            [IO.File]::WriteAllText((Join-Path $hb 'config.txt'), (($config -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))

            $cfg = @(
                '# vivac: written from Windows by scripts\apply-system.ps1 -Boot.',
                '# Sourced at the end of grub.cfg (41_custom), so the theme applies to',
                '# the menu whatever Arch regenerates. The theme follows the palette',
                '# chosen on Windows; remove this file to go back to the plain menu.',
                'if [ -f "$prefix/themes/vivac/theme.txt" ]; then',
                '  insmod png',
                '  insmod gfxmenu',
                '  set theme="$prefix/themes/vivac/theme.txt"',
                '  export theme',
                'fi',
                '',
                '# Windows through HackBGRT: the boot logo in the theme.',
                'menuentry "Windows 11" --class windows --class os --id vivac-windows {',
                '  insmod part_gpt',
                '  insmod fat',
                '  search --no-floppy --file --set=root /EFI/HackBGRT/loader.efi',
                '  chainloader /EFI/HackBGRT/loader.efi',
                '}'
            )
            [IO.File]::WriteAllText($customCfg, (($cfg -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        } finally {
            Dismount-VivacEsp $esp
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }

        # The sync script where only administrators can change it, and the
        # task that runs it as SYSTEM, which this user may start.
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'boot-sync.ps1') -Destination (Join-Path $installDir 'boot-sync.ps1') -Force
        $sync = Join-Path $installDir 'boot-sync.ps1'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$sync`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskPath '\vivac\' -TaskName 'boot-sync' -Action $action -Principal $principal -Settings $set -Force | Out-Null
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $task = $svc.GetFolder('\vivac').GetTask('boot-sync')
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # Read and run, not write: the user starts the task, never changes it.
        $task.SetSecurityDescriptor($task.GetSecurityDescriptor(4) + "(A;;GRGX;;;$who)", 0)

        # The stage: the user's to write, as the lock screen's folder is.
        $stage = Get-VivacBootStage
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        $acl = Get-Acl -LiteralPath $stage
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $stage -AclObject $acl
        # Drawing the stage starts headless Edge, which can refuse to run
        # elevated; the next theme switch, as the user, draws it then.
        try { [void](Write-VivacBootStage (Read-VivacTheme (Read-VivacSettings)['theme'])) }
        catch { Write-Warning "boot stage: $($_.Exception.Message)" }
        $before = Get-Date
        Start-VivacBootSync
        $logFile = Join-Path $installDir 'boot-sync.log'
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).LastWriteTime -ge $before -and
                (Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'boot-sync').State -ne 'Running') { break }
        }
        if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Tail 3 | ForEach-Object { Step $_ } }
    }
}
