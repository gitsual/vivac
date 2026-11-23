# The sound panel and the volume indicator: what they decide (names, the
# applications out of the mixer's sessions, what a redraw would change) and
# that they build from sample data in the palette, the way the Linux panel
# draws them. No audio device is needed: the panel's data comes through
# Get-VivacSoundData, which these cases replace.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\SoundLogic.psm1') -Force
Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
$surfaces = Get-Module Surfaces | Select-Object -First 1

function Get-Tree($o) {
    $o
    foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($o)) { if ($c -is [Windows.DependencyObject]) { Get-Tree $c } }
}
function Get-Texts($root) { @(Get-Tree $root | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object { if ($_.Inlines.Count -gt 1) { (@($_.Inlines | ForEach-Object { $_.Text }) -join '') } else { $_.Text } }) }

Case 'a device is named kind, then what carries it' {
    Assert-Equal "Speakers $([char]0x00B7) Realtek(R) Audio" (Get-SoundShortName 'Speakers (Realtek(R) Audio)')
    Assert-Equal "LG TV $([char]0x00B7) NVIDIA High Definition Audio" (Get-SoundShortName 'LG TV (NVIDIA High Definition Audio)')
    Assert-Equal 'Loopback' (Get-SoundShortName 'Loopback') 'a name with no parentheses stays as it is'
    Assert-Equal '(Only)' (Get-SoundShortName '(Only)') 'nothing before the parentheses: left alone'
    Assert-Equal '' (Get-SoundShortName '')
}
Case 'sessions of one program are one application: loudest level, muted only if all are, playing if any is' {
    $s = @(
        [pscustomobject]@{ Index = 2; ProcessId = 10; Name = 'Firefox'; Volume = 50; Muted = $false; Active = $false },
        [pscustomobject]@{ Index = 3; ProcessId = 10; Name = 'Firefox'; Volume = 80; Muted = $true; Active = $true },
        [pscustomobject]@{ Index = 1; ProcessId = 11; Name = 'mpv'; Volume = 100; Muted = $true; Active = $false },
        [pscustomobject]@{ Index = 0; ProcessId = 12; Name = 'audacity'; Volume = 5; Muted = $false; Active = $false })
    $apps = @(Group-SoundSessions $s)
    Assert-Equal 'audacity,Firefox,mpv' (($apps | ForEach-Object { $_.Name }) -join ',') 'sorted by name, ignoring case'
    $ff = $apps | Where-Object { $_.Name -eq 'Firefox' }
    Assert-Equal 80 $ff.Volume 'the loudest session'
    Assert-Equal $false $ff.Muted 'not muted while one session is not'
    Assert-Equal $true $ff.Playing 'playing while one session is'
    Assert-Equal '2,3' ($ff.Indexes -join ',') 'the row moves every session'
    Assert-Equal 'silenced' (Get-SoundAppState ($apps | Where-Object { $_.Name -eq 'mpv' }))
    Assert-Equal 'paused' (Get-SoundAppState ($apps | Where-Object { $_.Name -eq 'audacity' }))
    Assert-Equal 'playing' (Get-SoundAppState $ff)
    Assert-Equal 0 @(Group-SoundSessions @()).Count 'nothing playing is an empty list'
}
Case 'the signature changes when what is on screen would' {
    $d = { param($v, $m) [pscustomobject]@{ Id = 'o1'; IsDefault = $true; Volume = $v; Muted = $m } }
    $a = [pscustomobject]@{ Name = 'x'; Volume = 10; Muted = $false; Playing = $true; Indexes = @(1) }
    $one = Get-SoundSignature @(& $d 50 $false) @() @($a)
    Assert-Equal $one (Get-SoundSignature @(& $d 50 $false) @() @($a)) 'same data, same signature'
    Assert-True ($one -ne (Get-SoundSignature @(& $d 51 $false) @() @($a))) 'a level moved elsewhere'
    Assert-True ($one -ne (Get-SoundSignature @(& $d 50 $true) @() @($a))) 'muted elsewhere'
    Assert-True ($one -ne (Get-SoundSignature @(& $d 50 $false) @() @())) 'an application stopped'
}
Case 'the ruler under a fader: quarters of 100 here, the Linux 0/50/100/150 for a taller one' {
    Assert-Equal '0,25,50,75,100' ((Get-SoundRulerValues 100) -join ',')
    Assert-Equal '0,50,100,150' ((Get-SoundRulerValues 150) -join ',')
}

Case 'the real data comes back with its three lists, empty on a machine with no audio' {
    $d = & $surfaces { Get-VivacSoundData }
    foreach ($k in 'Outputs', 'Inputs', 'Apps') { Assert-True $d.ContainsKey($k) "no $k" }
}

# The panel, from sample data.
& $surfaces {
    function script:Get-VivacSoundData {
        $d = { param($id, $n, $def, $v, $m) [pscustomobject]@{ Id = $id; Name = $n; IsDefault = $def; Volume = $v; Muted = $m } }
        $a = { param($n, $v, $m, $pl, $ix) [pscustomobject]@{ Name = $n; ProcessId = [uint32]0; Volume = $v; Muted = $m; Playing = $pl; Indexes = $ix } }
        @{
            Outputs = @((& $d 'o1' 'Speakers (Realtek(R) Audio)' $true 70 $false), (& $d 'o2' 'Monitor (NVIDIA High Definition Audio)' $false 40 $false))
            Inputs = @((& $d 'i1' 'Microphone (Webcam)' $true 86 $false), (& $d 'i2' 'Line in (Realtek(R) Audio)' $false 50 $false))
            Apps = @((& $a 'paplay' 5 $false $true @(1)), (& $a 'mpv' 100 $true $false @(4)))
        }
    }
}
Case 'the sound panel draws the default output, each application and the inputs' {
    $w = Show-Sound -NoShow
    $all = @(Get-Tree $w)
    $faders = @($all | Where-Object { $_ -is [Windows.Controls.Slider] })
    Assert-Equal 4 $faders.Count 'the default output, two applications, the default input'
    foreach ($f in $faders) { Assert-Equal 100 $f.Maximum 'Windows tops out at 100' }
    Assert-Equal 70 $faders[0].Value 'the default output first'
    Assert-Equal "Speakers $([char]0x00B7) Realtek(R) Audio" $w.FindName('Subtitle').Text 'the header names the default output'
    $texts = Get-Texts $w
    Assert-True ($texts -contains 'paplay' -and $texts -contains 'mpv') 'both applications'
    Assert-True ($texts -contains '70%') 'the default output''s level in large type'
    $chips = @($all | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and $_.Tag.ContainsKey('Id') })
    Assert-Equal 2 $chips.Count 'one chip per output'
    $w.Close()
}
Case 'a machine with no audio draws the empty panel instead of failing' {
    & $surfaces { function script:Get-VivacSoundData { @{ Outputs = @(); Inputs = @(); Apps = @() } } }
    $w = Show-Sound -NoShow
    Assert-Equal (& $surfaces { T 'sound.none' }) $w.FindName('Subtitle').Text
    Assert-Equal 0 @(Get-Tree $w | Where-Object { $_ -is [Windows.Controls.Slider] }).Count 'nothing to adjust'
    $w.Close()
}

Case 'the volume indicator lights a notch per 4 per cent and shows the level in the palette' {
    $osd = New-VivacVolumeOsd
    Show-VivacVolumeOsd $osd 35 $false
    $lit = @($osd.Bar.Tag.Cells | Where-Object { $_.Background.Color.ToString() -eq ('#FF' + ((& $surfaces { (Get-KitTokens (Get-Palette))['accent'] }))) }).Count
    Assert-Equal 9 $lit '35 per cent of 26 notches'
    Assert-Equal '35%' (($osd.Window.FindName('Level').Inlines | ForEach-Object { $_.Text }) -join '')
    Show-VivacVolumeOsd $osd 100 $false
    Assert-Equal 26 @($osd.Bar.Tag.Cells | Where-Object { $_.Background.Color.ToString() -ne ('#FF' + ((& $surfaces { (Get-KitTokens (Get-Palette))['surfaceAlt'] }))) }).Count 'all of them at 100'
    Show-VivacVolumeOsd $osd 60 $true
    Assert-Equal 0 @($osd.Bar.Tag.Cells | Where-Object { $_.Background.Color.ToString() -ne ('#FF' + ((& $surfaces { (Get-KitTokens (Get-Palette))['surfaceAlt'] }))) }).Count 'none while muted'
    Assert-Equal (& $surfaces { T 'osd.muted' }) (($osd.Window.FindName('Level').Inlines | ForEach-Object { $_.Text }) -join '') 'muted says so instead of the number'
    Assert-Equal ([string][char]0xE74F) $osd.Window.FindName('Glyph').Text 'the mute glyph'
    $osd.Timer.Stop(); $osd.Window.Close()
}
Complete-Cases
