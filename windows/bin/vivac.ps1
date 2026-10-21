<#
.SYNOPSIS
  vivac's own surfaces, one verb each.

.DESCRIPTION
    menu        the menu of the Start menu's contents (MOD+R)
    help [pane] the key help pane (F1-F5 switch panes, Esc closes)
    power       the power menu: lock, sign out, sleep, restart, shut down
    theme       the theme picker
    theme from-image IMAGE [-Name N] [-DryRun] [-Apply]
                a new palette from a picture (scripts\theme-from-image.ps1)
    sound       the sound panel: devices, volumes and the mixer
    bluetooth   the Bluetooth panel: the radio, paired devices, pairing new ones
    network     the network panel: Wi-Fi networks and the wired adapters
    updates     the updates panel: Windows Update and the installed programs
    clipboard   without the resident host: Windows' clipboard history
    lock        lock the session (the lock screen wears the theme)
    notify T B  show a Windows notification
    welcome     the first-run wizard, in a terminal of its own
    security    Defender's state, in the palette: quick scan, signatures, history
    audit       the security audit

  The windows themselves live in lib/Surfaces.psm1; this file only picks one.
#>
param(
    [Parameter(Position = 0)][string]$Verb = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
# Without the resident host a surface takes a couple of seconds more to
# build: "Loading..." meanwhile, so the key does not look dead.
$fromImage = $Verb -eq 'theme' -and $Rest -and $Rest[0] -eq 'from-image'
if (@('menu', 'help', 'power', 'theme', 'sound', 'bluetooth', 'network', 'updates', 'security') -contains $Verb -and -not $fromImage) { Start-VivacLoading }

switch ($Verb) {
    'help'      { $pane = 'wm'; if ($Rest) { $pane = $Rest[0] }; Show-Help $pane }
    'menu'      { Show-Menu }
    'power'     { Show-Power }
    'theme'     {
        if ($fromImage) {
            $pictureArgs = @(@($Rest) | Select-Object -Skip 1)
            & (Join-Path $root 'scripts\theme-from-image.ps1') @pictureArgs
        }
        else { Show-ThemePicker }
    }
    'sound'     { Show-Sound }
    'bluetooth' { Import-Module (Join-Path $root 'lib\Bluetooth.psm1') -Force; Show-Bluetooth }
    'network'   { Import-Module (Join-Path $root 'lib\Network.psm1') -Force; Show-Network }
    'updates'   { Import-Module (Join-Path $root 'lib\Updates.psm1') -Force; Show-Updates }
    'security'  { Import-Module (Join-Path $root 'lib\Security.psm1') -Force; Show-Security }
    'clipboard' { Open-ClipboardHistory }
    'lock'      { Invoke-VivacLock }
    'notify'    { Show-Notification ([string]$Rest[0]) ((@($Rest) | Select-Object -Skip 1) -join ' ') }
    'welcome'   {
        $wizard = Join-Path $PSScriptRoot 'vivac-welcome.ps1'
        $wtArgs = @('--title', 'vivac-welcome', '--suppressApplicationTitle', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$wizard`"") + @($Rest | Where-Object { $_ })
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs
    }
    'audit'     { & (Join-Path $root 'scripts\security-audit.ps1') @Rest }
    default     { throw "vivac: unknown verb '$Verb' (menu, help, power, theme, sound, bluetooth, network, updates, security, clipboard, notify, welcome, audit)" }
}
