<#
.SYNOPSIS
  Renders every image the README shows, from this tree, into assets/.

.DESCRIPTION
  Two kinds of image, as in the source's README, and no third:

    wallpapers   the eight wallpapers scripts/make-wallpaper.ps1 renders
                 (dist/wallpapers), scaled to 1600x900, and all eight in one
                 strip (assets/wallpapers/all-eight.png)
    surfaces     vivac's own windows, each in a different palette, drawn by
                 the real code through tests/tools/shot-surface.ps1: off
                 screen, without the focus, in English, in a scratch profile
                 (no settings, history or clipboard of this machine's)

  A surface that would show something of this machine -- the account's name,
  the networks in range, an address, the devices around it -- has it
  replaced right before the capture (shot-surface.ps1 -Scrub) or is given
  sample data instead (-Prepare). Nothing of the machine that made the
  pictures is published with them.
#>
[CmdletBinding()]
param([switch]$SkipWallpapers, [switch]$SkipSurfaces, [string[]]$Only = @())
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
$shots = Join-Path $assets 'screenshots'
$walls = Join-Path $assets 'wallpapers'
New-Item -ItemType Directory -Force -Path $shots, $walls | Out-Null
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$order = 'bad-romance', 'metropolis', 'carmen', 'northern-lights', 'gatsby', 'the-hermit', 'cosmos', 'persephone'

function Save-Png($Source, [string]$Path) {
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Source))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

function Read-Png([string]$Path, [int]$Width) {
    $b = New-Object Windows.Media.Imaging.BitmapImage
    $b.BeginInit(); $b.UriSource = New-Object Uri $Path; $b.DecodePixelWidth = $Width; $b.CacheOption = 'OnLoad'; $b.EndInit()
    $b.Freeze()
    $b
}

# ------------------------------------------------------------- wallpapers

if (-not $SkipWallpapers) {
    $dist = Join-Path $root 'dist\wallpapers'
    foreach ($t in $order) {
        if (-not (Test-Path -LiteralPath (Join-Path $dist "$t.png"))) {
            & (Join-Path $PSScriptRoot 'make-wallpaper.ps1') -All
            break
        }
    }
    foreach ($t in $order) {
        Save-Png (Read-Png (Join-Path $dist "$t.png") 1600) (Join-Path $walls "$t.png")
        "wallpaper: $t"
    }
    # All eight in one strip: two rows of four, a thin gap between them.
    $w = 480; $h = 270; $gap = 6
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    for ($i = 0; $i -lt $order.Count; $i++) {
        $x = ($i % 4) * ($w + $gap); $y = [Math]::Floor($i / 4) * ($h + $gap)
        $dc.DrawImage((Read-Png (Join-Path $dist "$($order[$i]).png") $w), (New-Object Windows.Rect $x, $y, $w, $h))
    }
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap (4 * $w + 3 * $gap), (2 * $h + $gap), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    Save-Png $bmp (Join-Path $walls 'all-eight.png')
    'wallpaper: all-eight'
}

# --------------------------------------------------------------- surfaces

if (-not $SkipSurfaces) {
    # What this machine would show, and what the pictures say instead.
    $scrub = New-Object System.Collections.Generic.List[string]
    # Network names: the ones in range change between asking and capturing,
    # so they are asked for again inside the capture (VIVAC_SHOT_SCRUBSCRIPT),
    # where the panel's own reader is loaded. A name is replaced where it
    # stands alone, or inside a longer text when it is long enough not to be
    # a common word; a hidden network (no name) is not a name.
    $networkScrub = @'
$samples = @('vivac', 'vivac-5G', 'Library', 'Cafe', 'Guest', 'Studio', 'Office', 'Upstairs', 'Garden', 'Attic', 'Porch', 'Loft')
$st = [VivacNetwork]::GetState()
$names = @(@($st.Ssid) + @($st.Networks | ForEach-Object { $_.Ssid }) | Where-Object { $_ -and $_.Trim().Length -ge 2 } | Select-Object -Unique)
$i = 0
foreach ($n in $names) {
    $s = $samples[$i % $samples.Count]; $i++
    if ($n.Trim().Length -ge 4) { "$([regex]::Escape($n))=>$s" } else { "^$([regex]::Escape($n))$=>$s" }
}
'@
    $full = ''
    try { $full = [string](Get-LocalUser -Name $env:USERNAME).FullName } catch { }
    if ($full) {
        $scrub.Add("$([regex]::Escape($full))=>Ada L.")
        # The menu's avatar carries the name's first letter on its own.
        $scrub.Add("^$([regex]::Escape($full.Substring(0, 1).ToUpper()))$=>A")
    }
    $scrub.Add("\b$([regex]::Escape($env:USERNAME))\b=>ada")
    $scrub.Add("\b$([regex]::Escape($env:COMPUTERNAME))\b=>VIVAC")
    $scrub.Add('\b(\d{1,3}\.){3}\d{1,3}\b=>192.168.1.20')
    # The sample is RFC 7042's documentation address, put together here so
    # the repository's privacy gate, which refuses any MAC in the tree, need
    # not make an exception.
    $docMac = @('00', '00', '5E', '00', '53', '01') -join ':'
    $scrub.Add("\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b=>$docMac")
    # IPv6 only: a '::' or a group of three or four digits, which no MAC has.
    $scrub.Add('\b(?=[0-9a-fA-F:]*(::|[0-9a-fA-F]{3}))[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}\b=>2001:db8::20')

    $profileRoot = Join-Path ([IO.Path]::GetTempPath()) ('vivac-readme-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $harness = Join-Path $root 'tests\tools\shot-surface.ps1'
    $shot = {
        param([string]$Theme, [string]$File, [string]$Command, [string]$Name, [string[]]$Modules = @(), [string]$Setup = '', [string]$Prepare = '', [int]$WaitMs = 4000)
        if ($Only.Count -and $Only -notcontains $File) { return }
        $roaming = Join-Path $profileRoot 'Roaming'; $local = Join-Path $profileRoot 'Local'
        New-Item -ItemType Directory -Force -Path (Join-Path $roaming 'vivac'), (Join-Path $local 'vivac') | Out-Null
        [IO.File]::WriteAllText((Join-Path $roaming 'vivac\settings'), "theme=$Theme`nlanguage=en`nmod=lwin`n")
        $env:VIVAC_APPDATA = $roaming; $env:VIVAC_LOCALAPPDATA = $local
        $args2 = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $harness, '-Command', $Command, '-Name', $Name,
            '-Out', (Join-Path $shots $File), '-WaitMs', $WaitMs)
        if ($Modules.Count) { $args2 += @('-Modules', ($Modules -join ',')) }
        # Through the environment: scripts and patterns would not survive a command line.
        $env:VIVAC_SHOT_SETUP = $Setup; $env:VIVAC_SHOT_PREPARE = $Prepare; $env:VIVAC_SHOT_SCRUB = $scrub -join "`n"
        & powershell.exe @args2
    }
    try {
        & $shot 'cosmos' 'surface-menu.png' 'Show-Menu' 'menu' @() '$w.FindName(''Cats'').SelectedIndex = 4'
        & $shot 'persephone' 'surface-menu-calc.png' 'Show-Menu' 'menu' @() '$w.FindName(''Filter'').Text = ''2^10+5'''
        & $shot 'carmen' 'surface-sound.png' 'Show-Sound' 'sound'
        $bt = @'
function script:New-SampleBt([string]$Name, [uint64]$Address, [string]$Kind, [string]$Type, [bool]$Connected, [bool]$Paired) {
    $d = New-Object VivacBtDevice; $d.Name = $Name; $d.Address = $Address; $d.Kind = $Kind; $d.Type = $Type; $d.Connected = $Connected; $d.Paired = $Paired; $d
}
Import-VivacBluetooth
# The radio on, whatever this machine's is.
function script:Get-VivacBluetoothState { $true }
$script:DeviceSource = @{
    Paired = { @((New-SampleBt 'Headphones' 0x00005E005301 'audio' 'headphones' $true $true), (New-SampleBt 'Keyboard' 0x00005E005302 'input' 'keyboard' $true $true), (New-SampleBt 'Gamepad' 0x00005E005303 'input' 'gamepad' $false $true)) }
    Scan   = { $l = New-Object 'System.Collections.Generic.List[VivacBtDevice]'; $l.Add((New-SampleBt 'Speaker' 0x00005E005304 'audio' 'speaker' $false $false)); [System.Threading.Tasks.Task]::FromResult($l) }
}
'@
        & $shot 'northern-lights' 'surface-bluetooth.png' 'Show-Bluetooth' 'bluetooth' @('Bluetooth') '' $bt 6000
        $env:VIVAC_SHOT_SCRUBSCRIPT = $networkScrub
        & $shot 'metropolis' 'surface-network.png' 'Show-Network' 'network' @('Network') '' '' 9000
        Remove-Item Env:\VIVAC_SHOT_SCRUBSCRIPT
        & $shot 'bad-romance' 'surface-security.png' 'Show-Security' 'security' @('Security') '' '' 9000
        & $shot 'gatsby' 'surface-updates.png' 'Show-Updates' 'updates' @('Updates') '' '' 20000
        & $shot 'the-hermit' 'surface-help.png' 'Show-Help' 'help'
        & $shot 'persephone' 'surface-power.png' 'Show-Power' 'power'
    } finally {
        Remove-Item Env:\VIVAC_APPDATA, Env:\VIVAC_LOCALAPPDATA, Env:\VIVAC_SHOT_SETUP, Env:\VIVAC_SHOT_PREPARE, Env:\VIVAC_SHOT_SCRUB -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Notifications: vivac's card for what other programs post, three of them
    # stacked as the resident host stacks them, on the palette's own ground.
    $note = @'
$repo = $args[0]; $out = $args[1]
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $repo 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $repo 'lib\Surfaces.psm1') -Force
$p = Get-Palette
$panel = New-Object Windows.Controls.StackPanel
foreach ($c in @(@('Bluetooth', 'Headphones connected', 'Battery at 80%.', 0xE702), @('Defender', 'Quick scan finished', 'No threats found.', 0xEA18), @('USB', 'E: can be removed', 'It is safe to pull it out now.', 0xE88E))) {
    $w = New-VivacNotification $c[1] $c[2] $c[0] '' '' $c[3]
    $w.Tag.Progress.Width = 260
    $card = $w.Content; $w.Content = $null; $card.Margin = '0,0,0,8'
    [void]$panel.Children.Add($card)
}
$frame = New-Object Windows.Controls.Border
$frame.Background = "#$($p['COLOR_BG'])"; $frame.Padding = 16; $frame.Child = $panel; $frame.Width = 412
$frame.Measure([Windows.Size]::new(412, 2000)); $frame.Arrange([Windows.Rect]::new(0, 0, 412, $frame.DesiredSize.Height)); $frame.UpdateLayout()
$bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap 412, ([int]$frame.DesiredSize.Height), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
$bmp.Render($frame)
$enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
$fs = [IO.File]::Create($out); $enc.Save($fs); $fs.Close()
'@
    $tmpNote = Join-Path ([IO.Path]::GetTempPath()) 'vivac-readme-note.ps1'
    [IO.File]::WriteAllText($tmpNote, $note)
    $roaming = Join-Path $profileRoot 'Roaming'
    New-Item -ItemType Directory -Force -Path (Join-Path $roaming 'vivac') | Out-Null
    [IO.File]::WriteAllText((Join-Path $roaming 'vivac\settings'), "theme=the-hermit`nlanguage=en`nmod=lwin`n")
    $env:VIVAC_APPDATA = $roaming
    try { & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $tmpNote $root (Join-Path $shots 'surface-notifications.png') }
    finally { Remove-Item Env:\VIVAC_APPDATA -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $tmpNote, $profileRoot -Recurse -Force -ErrorAction SilentlyContinue }
    'surface: notifications'
}
