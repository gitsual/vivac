# Bluetooth, drawn by vivac: the radio, the devices Windows remembers and
# the ones in range, in the palette, dropping from the bar's right end as the
# sound panel does, instead of Windows' quick settings flyout (which went with
# the taskbar).
#
# The radio is switched through WinRT's Windows.Devices.Radios, the devices
# through the classic API in VivacBluetooth.cs. Pairing goes through
# bin/vivac-tray.ps1 -Pair in a process of its own: Windows may ask for a
# code in a window of its own, which would take the focus and so close this
# one, and the pairing has to outlive it.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')

$script:Helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-tray.ps1'
$script:AsTask = $null

function Import-VivacBluetooth {
    if ('VivacBluetooth' -as [type]) { return }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacBluetooth.cs'))) -Language CSharp
}

# WinRT from Windows PowerShell: an IAsyncOperation is awaited through the
# AsTask extension, made generic for the type it returns.
function Wait-VivacWinRt($Operation, [type]$Type) {
    if (-not $script:AsTask) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $script:AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    }
    $task = $script:AsTask.MakeGenericMethod($Type).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    $task.Result
}

function Get-VivacBluetoothRadio {
    $null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
    $radios = Wait-VivacWinRt ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    $radios | Where-Object { $_.Kind -eq 'Bluetooth' } | Select-Object -First 1
}

# On, off, or $null when the machine has no radio to switch.
function Get-VivacBluetoothState {
    try {
        $radio = Get-VivacBluetoothRadio
        if ($radio) { return [string]$radio.State -eq 'On' }
    } catch { }
    $null
}

function Set-VivacBluetoothState([bool]$On) {
    $radio = Get-VivacBluetoothRadio
    if (-not $radio) { return $false }
    $access = Wait-VivacWinRt ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
    if ([string]$access -ne 'Allowed') { return $false }
    $state = if ($On) { [Windows.Devices.Radios.RadioState]::On } else { [Windows.Devices.Radios.RadioState]::Off }
    [string](Wait-VivacWinRt ($radio.SetStateAsync($state)) ([Windows.Devices.Radios.RadioAccessStatus])) -eq 'Allowed'
}

# Where the panel reads devices from: the classic API, the remembered ones at
# once and, with inquiry, the ones in range as a task. tests/tools may put
# sample devices here, for looking at the panel on a machine without any.
$script:DeviceSource = @{
    Paired = { @([VivacBluetooth]::Devices($false, 0) | Where-Object { $_.Paired }) }
    Scan   = { [VivacBluetooth]::Scan(4) }
}

# The battery Windows reads from a device that reports one (hands-free
# headsets mostly), keyed by the address as 12 hex digits. Asking PnP takes
# a second or two, so it runs off the window's thread.
$script:BatteryScript = {
    param([string[]]$Addresses)
    $out = @{}
    foreach ($dev in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^(BTHENUM|BTHHFENUM|BTHLE)' })) {
        foreach ($a in $Addresses) {
            if ($out.ContainsKey($a) -or $dev.InstanceId -notmatch $a) { continue }
            $b = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2' -ErrorAction SilentlyContinue
            if ($b -and $null -ne $b.Data) { $out[$a] = [int]$b.Data }
        }
    }
    $out
}

function Show-Bluetooth([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'bluetooth' }
    $surfaceName = 'bluetooth'
    Import-VivacBluetooth
    $p = Get-Palette
    $iconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $source = $script:DeviceSource
    $batteryScript = $script:BatteryScript
    $helper = $script:Helper
    $body = @"
<DockPanel>
  <Button x:Name="More" DockPanel.Dock="Bottom" Style="{StaticResource KitGhost}" HorizontalAlignment="Stretch" Margin="0,10,0,0">
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="$(Get-KitGlyph 0xE713)" FontFamily="$iconFont" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock Text="$(ConvertTo-XmlText (T 'bt.more'))" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel x:Name="Sections"/>
  </ScrollViewer>
</DockPanel>
"@
    $hints = @(@('F5', (T 'bt.key.scan')), @('Esc', (T 'bt.key.close')))
    $window = New-VivacWindow (Get-WindowXaml 'vivac - bluetooth' 440 560 (Get-KitPanelXaml $p 0xE702 'Bluetooth' $body $hints))
    Set-KitDropDown $window
    $kit = $window.Content.Child
    $sections = $window.FindName('Sections')
    $subtitle = $window.FindName('Subtitle')
    $window.FindName('More').Add_Click({ $window.Close(); Start-Process 'ms-settings:bluetooth' })

    # The radio's switch, in the header.
    $radio = New-Object Windows.Controls.Primitives.ToggleButton
    $radio.Style = $kit.FindResource('KitSwitch')
    [void]$window.FindName('HeaderRight').Children.Add($radio)

    # What the panel holds between renders. Busy maps an address to the word
    # its row shows while something runs on it; Forget is the one address
    # whose second click on its bin forgets it.
    $state = @{
        On = Get-VivacBluetoothState; Paired = @(); Nearby = @(); Scan = $null; Scanned = $false
        Busy = @{}; Jobs = @(); Forget = $null; Note = ''; NoteBad = $false; Wake = $null; ScanOnWake = $false
        Battery = @{}; BatteryJob = $null; Painting = $false
    }

    $typeGlyph = @{
        headphones = 0xE7F6; headset = 0xE95B; speaker = 0xE7F5; car = 0xE804; keyboard = 0xE765; mouse = 0xE962
        gamepad = 0xE7FC; phone = 0xE8EA; computer = 0xE7F8; watch = 0xE916; other = 0xE702
    }
    # A device from an older build of VivacBluetooth.cs (a resident host that
    # loaded it before) has no Type; its class of device still says it.
    $typeOf = {
        param($d)
        if ($d.PSObject.Properties['Type'] -and $d.Type) { return [string]$d.Type }
        [string]$d.Kind
    }
    $hex = { param($d) '{0:X12}' -f $d.Address }

    $newText = {
        param([string]$Text, [string]$Color, [double]$Size = 13)
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text; $t.Foreground = "#$Color"; $t.FontSize = $Size
        $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'
        $t
    }
    $newButton = {
        param([string]$Style, [int]$Glyph, [string]$Text, [scriptblock]$OnClick, $Device)
        $b = New-Object Windows.Controls.Button
        $b.Style = $kit.FindResource($Style)
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        if ($Glyph) {
            $g = New-Object Windows.Controls.TextBlock
            $g.Text = Get-KitGlyph $Glyph; $g.FontFamily = $iconFont; $g.FontSize = 12; $g.VerticalAlignment = 'Center'
            if ($Text) { $g.Margin = '0,0,6,0' }
            [void]$sp.Children.Add($g)
        }
        if ($Text) { $t = New-Object Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = 12; $t.VerticalAlignment = 'Center'; [void]$sp.Children.Add($t) }
        $b.Content = $sp
        $b.Margin = '6,0,0,0'
        # What the handler needs travels in the Tag: it runs after this block
        # has returned.
        $b.Tag = @{ Run = $OnClick; Device = $Device }
        $b.Add_Click({ param($s) & $s.Tag.Run $s.Tag.Device })
        $b
    }
    $newHeader = {
        param([string]$Text, [int]$Count = -1, $Right = $null)
        $g = New-Object Windows.Controls.DockPanel
        $g.Margin = '2,12,0,6'
        if ($Right) { [Windows.Controls.DockPanel]::SetDock($Right, 'Right'); [void]$g.Children.Add($Right) }
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.VerticalAlignment = 'Center'
        $t = & $newText $Text.ToUpper() $p['COLOR_ACCENT'] 11
        $t.FontWeight = 'SemiBold'
        [void]$sp.Children.Add($t)
        if ($Count -ge 0) { $c = & $newText "  $Count" $p['COLOR_MUTED'] 11; [void]$sp.Children.Add($c) }
        [void]$g.Children.Add($sp)
        $g
    }
    # A row in a card of its own: the menu's row, with the device's glyph in
    # the colour of its state.
    $newCard = {
        param($Row)
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 10; $card.Padding = '10,4'; $card.Margin = '0,0,0,6'
        $card.Background = "#$($p['COLOR_SURFACE'])"
        $Row.Tag.Tile.Background = "#$($p['COLOR_BG'])"
        $card.Child = $Row
        $card
    }
    $newNote = {
        param([int]$Glyph, [string]$Text, [string]$Color)
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 10; $card.Padding = '12,10'; $card.Margin = '0,0,0,6'
        $card.Background = "#$($p['COLOR_SURFACE'])"
        $dp = New-Object Windows.Controls.DockPanel
        $g = & $newText (Get-KitGlyph $Glyph) $Color 15
        $g.FontFamily = $iconFont; $g.Margin = '0,0,10,0'; $g.VerticalAlignment = 'Top'
        [Windows.Controls.DockPanel]::SetDock($g, 'Left')
        [void]$dp.Children.Add($g)
        $t = & $newText $Text $p['COLOR_FG'] 12
        $t.TextWrapping = 'Wrap'; $t.TextTrimming = 'None'
        [void]$dp.Children.Add($t)
        $card.Child = $dp
        $card
    }
    # A thin bar that runs while the search does.
    $newSweep = {
        [Windows.Markup.XamlReader]::Parse(@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Height="3" CornerRadius="2" Margin="2,0,2,8" Background="#$($p['COLOR_SURFACE'])" ClipToBounds="True">
  <Border Width="90" HorizontalAlignment="Left" CornerRadius="2" Background="#$($p['COLOR_ACCENT'])">
    <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
    <Border.Triggers>
      <EventTrigger RoutedEvent="FrameworkElement.Loaded">
        <BeginStoryboard><Storyboard RepeatBehavior="Forever">
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="-90" To="420" Duration="0:0:1.4"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
    </Border.Triggers>
  </Border>
</Border>
"@)
    }

    $startScan = {
        if (-not $state.On -or $state.Scan) { return }
        $state.Scan = & $source.Scan
    }
    $startBattery = {
        if ($state.BatteryJob) { return }
        $addresses = [string[]]@($state.Paired | Where-Object { $_.Connected } | ForEach-Object { & $hex $_ })
        if (-not $addresses.Count) { return }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($batteryScript).AddArgument($addresses)
        $state.BatteryJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    # Connecting is a service change on the driver; it runs on a worker and
    # the timer below picks the answer up.
    $toggleConnection = {
        param($d)
        if (-not [VivacBluetooth]::CanConnect($d.Kind) -or $state.Busy.ContainsKey($d.Address)) { return }
        $state.Forget = $null
        $state.Busy[$d.Address] = $(if ($d.Connected) { T 'bt.disconnecting' } else { T 'bt.connecting' })
        $state.Jobs += , @{ Address = $d.Address; Name = $d.Name; Task = [VivacBluetooth]::SetConnectedAsync($d.Address, -not $d.Connected) }
        & $render
    }
    $forget = {
        param($d)
        if ($state.Forget -ne $d.Address) { $state.Forget = $d.Address; & $render; return }
        $state.Forget = $null
        [void][VivacBluetooth]::Forget($d.Address)
        $state.Note = T 'bt.forgot' @($d.Name); $state.NoteBad = $false
        & $refresh
    }
    $pair = {
        param($d)
        Invoke-Detached $helper @('-Pair', (& $hex $d))
        $window.Close()
    }
    $switchRadio = {
        if ($null -eq $state.On) { return }
        if (Set-VivacBluetoothState (-not $state.On)) {
            $state.On = -not $state.On
            $state.Note = ''
            if ($state.On) {
                # The radio takes a moment to come up before it can search.
                $state.Scanned = $false
                $state.Paired = @(); $state.Nearby = @()
                $state.Wake = [DateTime]::Now.AddSeconds(2); $state.ScanOnWake = $true
            } else { $state.Nearby = @(); $state.Scan = $null }
        }
        & $refresh
    }

    $refresh = {
        $state.Paired = @()
        if ($state.On) { $state.Paired = @(& $source.Paired) }
        & $render
        & $startBattery
    }

    # One paired device: what it is and how it is, and its buttons.
    $deviceRow = {
        param($d)
        $type = & $typeOf $d
        $glyph = $typeGlyph[$type]
        if (-not $glyph) { $glyph = $typeGlyph['other'] }
        # The section already says whether it is connected.
        $sub = T "bt.type.$type"
        $color = $p['COLOR_MUTED']
        $busy = $state.Busy.ContainsKey($d.Address)
        if ($busy) { $sub = $state.Busy[$d.Address]; $color = $p['COLOR_ACCENT'] }
        $pct = $null
        if (-not $busy -and $d.Connected) {
            $color = $p['COLOR_OK']
            $pct = $state.Battery[(& $hex $d)]
        }

        $right = New-Object Windows.Controls.StackPanel
        $right.Orientation = 'Horizontal'
        if (-not $busy) {
            if ([VivacBluetooth]::CanConnect($d.Kind)) {
                if ($d.Connected) { [void]$right.Children.Add((& $newButton 'KitGhost' 0 (T 'bt.btn.disconnect') $toggleConnection $d)) }
                else { [void]$right.Children.Add((& $newButton 'KitButton' 0 (T 'bt.btn.connect') $toggleConnection $d)) }
            }
            if ($state.Forget -eq $d.Address) {
                $b = & $newButton 'KitButton' 0xE74D (T 'bt.forget_again') $forget $d
                $b.Background = "#$($p['COLOR_URGENT'])"
            } else {
                $b = & $newButton 'KitGhost' 0xE74D '' $forget $d
                $b.ToolTip = T 'bt.forget'
            }
            [void]$right.Children.Add($b)
        }
        $row = New-KitRow $p $glyph $d.Name $sub $right $color
        if ($busy) { $row.Tag.Sub.Foreground = "#$($p['COLOR_ACCENT'])" }
        # The battery as Windows' own gauge glyph (Battery0..Battery10) and
        # the figure, after the kind.
        if ($null -ne $pct) {
            $level = [Math]::Max(0, [Math]::Min(10, [int][Math]::Floor($pct / 10)))
            $code = if ($level -eq 10) { 0xE83F } else { 0xE850 + $level }
            $run = New-Object Windows.Documents.Run (Get-KitGlyph $code)
            $run.FontFamily = $iconFont
            if ($pct -le 20) { $run.Foreground = "#$($p['COLOR_URGENT'])" }
            [void]$row.Tag.Sub.Inlines.Add((New-Object Windows.Documents.Run "    "))
            [void]$row.Tag.Sub.Inlines.Add($run)
            [void]$row.Tag.Sub.Inlines.Add((New-Object Windows.Documents.Run " $pct %"))
            $row.ToolTip = T 'bt.battery' @([string]$pct)
        }
        $card = & $newCard $row
        if ($d.Connected) { $row.Tag.Tile.Background = "#33$($p['COLOR_OK'])" }
        $card
    }

    $render = {
        if ($state.Painting) { return }
        $state.Painting = $true
        try {
            $sections.Children.Clear()
            $connected = @($state.Paired | Where-Object { $_.Connected } | Sort-Object Name)
            $resting = @($state.Paired | Where-Object { -not $_.Connected } | Sort-Object Name)
            $radio.IsEnabled = $null -ne $state.On
            $radio.IsChecked = [bool]$state.On
            if ($null -eq $state.On) { $subtitle.Text = T 'bt.no_radio' }
            elseif (-not $state.On) { $subtitle.Text = T 'bt.off' }
            else { $subtitle.Text = T 'bt.summary' @([string]$connected.Count, [string]$state.Paired.Count) }

            if ($state.Note) {
                $c = $p['COLOR_ACCENT']; $g = 0xE946
                if ($state.NoteBad) { $c = $p['COLOR_URGENT']; $g = 0xE7BA }
                [void]$sections.Children.Add((& $newNote $g $state.Note $c))
            }
            if ($null -eq $state.On) {
                [void]$sections.Children.Add((& $newNote 0xE702 (T 'bt.no_radio') $p['COLOR_MUTED']))
                return
            }
            if (-not $state.On) {
                $card = & $newNote 0xE702 (T 'bt.off_note') $p['COLOR_MUTED']
                $on = & $newButton 'KitButton' 0xE7E8 (T 'bt.btn.turn_on') $switchRadio $null
                $on.HorizontalAlignment = 'Left'; $on.Margin = '25,10,0,0'
                $wrap = New-Object Windows.Controls.StackPanel
                $card.Child.Children[1].TextWrapping = 'Wrap'
                $old = $card.Child; $card.Child = $null
                [void]$wrap.Children.Add($old); [void]$wrap.Children.Add($on)
                $card.Child = $wrap
                [void]$sections.Children.Add($card)
                return
            }

            if ($connected.Count) {
                [void]$sections.Children.Add((& $newHeader (T 'bt.section.connected') $connected.Count))
                foreach ($d in $connected) { [void]$sections.Children.Add((& $deviceRow $d)) }
            }
            [void]$sections.Children.Add((& $newHeader (T 'bt.section.paired') $resting.Count))
            if (-not $state.Paired.Count) { [void]$sections.Children.Add((& $newNote 0xE946 (T 'bt.none_paired') $p['COLOR_MUTED'])) }
            elseif (-not $resting.Count) { [void]$sections.Children.Add((& $newText (T 'bt.all_connected') $p['COLOR_MUTED'] 12)) }
            foreach ($d in $resting) { [void]$sections.Children.Add((& $deviceRow $d)) }

            $known = @($state.Paired | ForEach-Object { $_.Address })
            $near = @($state.Nearby | Where-Object { -not $_.Paired -and $known -notcontains $_.Address } | Sort-Object Name)
            $scanBtn = $null
            if (-not $state.Scan) { $scanBtn = & $newButton 'KitGhost' 0xE72C (T 'bt.btn.scan') { & $startScan; & $render } $null }
            [void]$sections.Children.Add((& $newHeader (T 'bt.section.nearby') $(if ($state.Scan) { -1 } else { $near.Count }) $scanBtn))
            if ($state.Scan) {
                [void]$sections.Children.Add((& $newSweep))
                $t = & $newText (T 'bt.scanning') $p['COLOR_MUTED'] 12
                $t.Margin = '2,0,0,8'
                [void]$sections.Children.Add($t)
            } elseif (-not $near.Count -and $state.Scanned) {
                [void]$sections.Children.Add((& $newNote 0xE946 (T 'bt.none_near') $p['COLOR_MUTED']))
            }
            foreach ($d in $near) {
                $type = & $typeOf $d
                $glyph = $typeGlyph[$type]
                if (-not $glyph) { $glyph = $typeGlyph['other'] }
                $btn = & $newButton 'KitButton' 0xE71B (T 'bt.btn.pair') $pair $d
                $row = New-KitRow $p $glyph $d.Name "$(T "bt.type.$type")  $([char]0x00B7)  $([VivacBluetooth]::FormatAddress($d.Address))" $btn $p['COLOR_INFO']
                [void]$sections.Children.Add((& $newCard $row))
            }
        } finally { $state.Painting = $false }
    }

    # The switch is the radio: a click asks Windows, and the switch shows
    # whatever the radio ends up as.
    $radio.Add_Click({ & $switchRadio })

    # The searches, connections and battery reads running on workers report here.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
            $dirty = $false
            if ($state.Wake -and [DateTime]::Now -ge $state.Wake) {
                $state.Wake = $null
                if ($state.ScanOnWake) { $state.ScanOnWake = $false; & $startScan }
                $dirty = $true
            }
            if ($state.Scan -and $state.Scan.IsCompleted) {
                if (-not $state.Scan.IsFaulted) { $state.Nearby = @($state.Scan.Result) }
                $state.Scan = $null; $state.Scanned = $true
                $dirty = $true
            }
            foreach ($j in @($state.Jobs | Where-Object { $_.Task.IsCompleted })) {
                $state.Busy.Remove($j.Address)
                if ($j.Task.IsFaulted -or $j.Task.Result -ne 0) { $state.Note = T 'bt.connect_failed' @($j.Name); $state.NoteBad = $true }
                else { $state.Note = '' }
                $state.Jobs = @($state.Jobs | Where-Object { $_ -ne $j })
                # The driver answers before the link is up; asking again a
                # moment later reads the state it settled on.
                $state.Wake = [DateTime]::Now.AddSeconds(2)
                $dirty = $true
            }
            $bj = $state.BatteryJob
            if ($bj -and $bj.Handle.IsCompleted) {
                try { $r = $bj.PS.EndInvoke($bj.Handle); if ($r.Count -and $r[0] -is [hashtable]) { $state.Battery = $r[0] } } catch { }
                $bj.PS.Dispose(); $state.BatteryJob = $null
                $dirty = $true
            }
            if ($dirty) {
                $state.Paired = @()
                if ($state.On) { $state.Paired = @(& $source.Paired) }
                & $render
            }
        })
    # Closed can fire after this function has returned (the resident host
    # builds the panel once and closes it), so the timer travels with it.
    $window.Add_Closed({ $timer.Stop() }.GetNewClosure())

    $window.Add_PreviewKeyDown({
            param($s, $e)
            $k = [string]$e.Key
            if ($k -eq 'Escape') { $window.Close(); $e.Handled = $true }
            elseif ($k -eq 'F5') { & $startScan; & $render; $e.Handled = $true }
        })
    & $refresh
    if ($NoShow) { return $window }
    $timer.Start()
    & $startScan
    & $render
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Import-VivacBluetooth, Get-VivacBluetoothState, Set-VivacBluetoothState, Show-Bluetooth
