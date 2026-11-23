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
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')
Import-Module (Join-Path $PSScriptRoot 'BtIcons.psm1')

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
    Register-BtIcons
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $source = $script:DeviceSource
    $batteryScript = $script:BatteryScript
    $helper = $script:Helper
    $moreButton = Get-PanelButtonXaml $t 'More' (T 'bt.more') 'sliders' 'neutral' 42 'HorizontalAlignment="Stretch"'
    $body = @"
<DockPanel>
  <Border DockPanel.Dock="Bottom" Margin="0,10,0,0">$moreButton</Border>
  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-8,0">
    <StackPanel x:Name="Sections" Margin="0,0,8,0"/>
  </ScrollViewer>
</DockPanel>
"@
    $hints = @(@('F5', (T 'bt.key.scan')), @([string][char]0x21B5, (T 'bt.key.connect')), @('Esc', (T 'bt.key.close')))
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - bluetooth' 500 (Get-KitPanelXamlV2 $t (Get-KitGlyph 0xE702) 'Bluetooth' $body $hints))
    Add-KitDrawResources $window $p
    Set-KitDropDown $window
    $window.MaxHeight = [Math]::Max(420, [Windows.SystemParameters]::WorkArea.Height - 40)
    $sections = $window.FindName('Sections')
    $subtitle = $window.FindName('Subtitle')
    $window.FindName('More').Add_Click({ $window.Close(); Start-Process 'ms-settings:bluetooth' })

    # The radio's switch, in the header: the design's 52 x 30 track.
    $radio = ConvertTo-PanelElement @"
<ToggleButton Cursor="Hand" FocusVisualStyle="{x:Null}"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
  <Border x:Name="Track" Width="52" Height="30" CornerRadius="15" Background="#$($t.surfaceAlt)">
    <Ellipse x:Name="Knob" Width="22" Height="22" Margin="4,0" HorizontalAlignment="Left" Fill="#$($t.muted)"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsChecked" Value="True">
      <Setter TargetName="Track" Property="Background" Value="#$($t.accent)"/>
      <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
      <Setter TargetName="Knob" Property="Fill" Value="#$($t.bg)"/>
    </Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Track" Property="Opacity" Value="0.4"/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate></ToggleButton.Template></ToggleButton>
"@
    [void]$window.FindName('HeaderRight').Children.Add($radio)

    # What the panel holds between renders. Busy maps an address to the word
    # its row shows while something runs on it; Forget is the one address
    # whose second click on its bin forgets it.
    $state = @{
        On = Get-VivacBluetoothState; Paired = @(); Nearby = @(); Scan = $null; Scanned = $false
        Busy = @{}; Jobs = @(); Forget = $null; Note = ''; NoteBad = $false; Wake = $null; ScanOnWake = $false
        Battery = @{}; BatteryJob = $null; Painting = $false
    }

    $typeIcon = @{
        headphones = 'headphones'; headset = 'headphones'; speaker = 'speaker'; car = 'car'; keyboard = 'keyboard'; mouse = 'mouse'
        gamepad = 'gamepad'; phone = 'phone'; computer = 'computer'; watch = 'watch'; other = 'bluetooth'
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
        $x = New-Object Windows.Controls.TextBlock
        $x.Text = $Text; $x.Foreground = "#$Color"; $x.FontSize = $Size
        $x.VerticalAlignment = 'Center'; $x.TextTrimming = 'CharacterEllipsis'
        $x
    }
    # A kit button (Kind: primary, neutral, danger); no text makes it a
    # square one. What the handler needs travels in the Tag: it runs after
    # this block has returned.
    $newButton = {
        param([string]$Kind, [string]$Icon, [string]$Text, [scriptblock]$OnClick, $Device, [int]$Height = 34)
        $extra = ''
        if (-not $Text) { $extra = 'Width="34"' }
        $b = ConvertTo-PanelElement (Get-PanelButtonXaml $t '' $Text $Icon $Kind $Height $extra)
        $b.Margin = '8,0,0,0'
        $b.Tag = @{ Run = $OnClick; Device = $Device }
        $b.Add_Click({ param($s) & $s.Tag.Run $s.Tag.Device })
        $b
    }
    $newHeader = {
        param([string]$Text, [int]$Count = -1, $Right = $null)
        $pill = $null
        if ($Count -ge 0) { $pill = $Count }
        $dp = New-Object Windows.Controls.DockPanel
        $dp.Margin = '0,10,0,6'
        if ($Right) { [Windows.Controls.DockPanel]::SetDock($Right, 'Right'); [void]$dp.Children.Add($Right) }
        [void]$dp.Children.Add((ConvertTo-PanelElement (Get-PanelSectionXaml $t $Text '' $pill '2,0,0,0')))
        $dp
    }
    # A card: the surface block of 12 px corners, with $Child inside.
    $newCard = {
        param($Child)
        $card = ConvertTo-PanelElement (Get-PanelCardXaml $t '<ContentControl x:Name="Slot" IsTabStop="False"/>' 'ok' '0,0,0,8')
        $card.Padding = '10'
        $card.Child = $Child
        $card
    }
    $newNote = {
        param([string]$Icon, [string]$Text, [string]$Color, [bool]$Bad = $false)
        $level = 'ok'
        if ($Bad) { $level = 'alert' }
        $card = ConvertTo-PanelElement (Get-PanelCardXaml $t "<DockPanel><Viewbox x:Name=`"NoteIcon`" DockPanel.Dock=`"Left`" Width=`"1`" Height=`"1`"/><TextBlock x:Name=`"NoteText`" TextWrapping=`"Wrap`" FontSize=`"12`" VerticalAlignment=`"Center`" Foreground=`"#$($t.text)`"/></DockPanel>" $level '0,0,0,8')
        $dp = $card.Child
        $dp.Children.Clear()
        $mark = ConvertTo-PanelElement (Get-PanelIconXaml $Icon 18 $Color 2 'Margin="0,0,10,0" VerticalAlignment="Top"')
        [Windows.Controls.DockPanel]::SetDock($mark, 'Left')
        [void]$dp.Children.Add($mark)
        $x = & $newText $Text $t.text 12
        $x.TextWrapping = 'Wrap'; $x.TextTrimming = 'None'
        [void]$dp.Children.Add($x)
        $card
    }
    # A thin bar that runs while the search does.
    $newSweep = {
        [Windows.Markup.XamlReader]::Parse(@"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Height="3" CornerRadius="2" Margin="2,0,2,8" Background="#$($t.surface)" ClipToBounds="True">
  <Border Width="90" HorizontalAlignment="Left" CornerRadius="2" Background="#$($t.accent)">
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
    # One device: tile, name over a line, then what goes on its right.
    $newRow = {
        param([string]$Icon, [string]$Name, [string]$Sub, [string]$SubColor, [object[]]$Right)
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto') {
            $c = New-Object Windows.Controls.ColumnDefinition
            $c.Width = [Windows.GridLengthConverter]::new().ConvertFromString($w)
            $g.ColumnDefinitions.Add($c)
        }
        $tile = ConvertTo-PanelElement (Get-PanelTileXaml $t $Icon 40)
        $tile.VerticalAlignment = 'Center'
        [void]$g.Children.Add($tile)
        $st = New-Object Windows.Controls.StackPanel
        $st.VerticalAlignment = 'Center'; $st.Margin = '12,0,8,0'
        $n = & $newText $Name $t.text 14
        $n.FontWeight = 'Bold'
        [void]$st.Children.Add($n)
        [void]$st.Children.Add((& $newText $Sub $SubColor 12))
        [Windows.Controls.Grid]::SetColumn($st, 1)
        [void]$g.Children.Add($st)
        $r = New-Object Windows.Controls.StackPanel
        $r.Orientation = 'Horizontal'; $r.VerticalAlignment = 'Center'
        foreach ($e in $Right) { if ($e) { [void]$r.Children.Add($e) } }
        [Windows.Controls.Grid]::SetColumn($r, 2)
        [void]$g.Children.Add($r)
        $g
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
        $icon = $typeIcon[$type]
        if (-not $icon) { $icon = $typeIcon['other'] }
        $sub = "$(T "bt.type.$type")  $([char]0x00B7)  $(if ($d.Connected) { T 'bt.connected' } else { T 'bt.not_connected' })"
        $subColor = $t.textSecondary
        $busy = $state.Busy.ContainsKey($d.Address)
        if ($busy) { $sub = $state.Busy[$d.Address]; $subColor = $t.accent }
        $pct = $null
        if (-not $busy -and $d.Connected) { $pct = $state.Battery[(& $hex $d)] }

        $right = @()
        # The battery: the design's cell outline and the figure.
        if ($null -ne $pct) {
            $color = $t.success
            if ($pct -le 20) { $color = $t.alert }
            $bat = New-Object Windows.Controls.StackPanel
            $bat.Orientation = 'Horizontal'; $bat.VerticalAlignment = 'Center'
            [void]$bat.Children.Add((ConvertTo-PanelElement (Get-PanelIconXaml 'battery' 16 $color 2 'Margin="0,0,5,0" VerticalAlignment="Center"')))
            [void]$bat.Children.Add((& $newText "$pct %" $color 12))
            $bat.ToolTip = T 'bt.battery' @([string]$pct)
            $right += $bat
        }
        if (-not $busy) {
            $canConnect = [VivacBluetooth]::CanConnect($d.Kind)
            if ($canConnect) {
                if ($d.Connected) { $right += (& $newButton 'neutral' '' (T 'bt.btn.disconnect') $toggleConnection $d) }
                else {
                    $b = & $newButton 'primary' '' (T 'bt.btn.connect') $toggleConnection $d
                    if (-not $state.FirstPrimary) { $state.FirstPrimary = $b }
                    $right += $b
                }
            }
            if ($state.Forget -eq $d.Address) {
                $right += (& $newButton 'danger' 'trash' (T 'bt.forget_again') $forget $d)
            } else {
                $b = & $newButton 'neutral' 'trash' '' $forget $d
                $b.ToolTip = T 'bt.forget'
                $right += $b
            }
        }
        & $newCard (& $newRow $icon $d.Name $sub $subColor $right)
    }

    $render = {
        if ($state.Painting) { return }
        $state.Painting = $true
        $state.FirstPrimary = $null
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
                $c = $t.accent; $g = 'bluetooth'
                if ($state.NoteBad) { $c = $t.alert; $g = 'warn' }
                [void]$sections.Children.Add((& $newNote $g $state.Note $c $state.NoteBad))
            }
            if ($null -eq $state.On) {
                [void]$sections.Children.Add((& $newNote 'bluetooth' (T 'bt.no_radio') $t.muted))
                return
            }
            if (-not $state.On) {
                $card = & $newNote 'bluetooth' (T 'bt.off_note') $t.muted
                $on = & $newButton 'primary' '' (T 'bt.btn.turn_on') $switchRadio $null
                $on.HorizontalAlignment = 'Left'; $on.Margin = '28,10,0,0'
                $dp = $card.Child
                $wrap = New-Object Windows.Controls.StackPanel
                $card.Child = $null
                [void]$wrap.Children.Add($dp); [void]$wrap.Children.Add($on)
                $card.Child = $wrap
                [void]$sections.Children.Add($card)
                return
            }

            if ($connected.Count) {
                [void]$sections.Children.Add((& $newHeader (T 'bt.section.connected') $connected.Count))
                foreach ($d in $connected) { [void]$sections.Children.Add((& $deviceRow $d)) }
            }
            [void]$sections.Children.Add((& $newHeader (T 'bt.section.paired') $resting.Count))
            if (-not $state.Paired.Count) { [void]$sections.Children.Add((& $newNote 'bluetooth' (T 'bt.none_paired') $t.muted)) }
            elseif (-not $resting.Count) { $x = & $newText (T 'bt.all_connected') $t.muted 12; $x.Margin = '2,0,0,8'; [void]$sections.Children.Add($x) }
            foreach ($d in $resting) { [void]$sections.Children.Add((& $deviceRow $d)) }

            $known = @($state.Paired | ForEach-Object { $_.Address })
            $near = @($state.Nearby | Where-Object { -not $_.Paired -and $known -notcontains $_.Address } | Sort-Object Name)
            # Right of the heading: the search button, or while it runs the
            # word for it with the refresh icon.
            $right = $null
            if (-not $state.Scan) { $right = & $newButton 'neutral' 'refresh' (T 'bt.btn.scan') { & $startScan; & $render } $null 28 }
            else {
                $right = New-Object Windows.Controls.StackPanel
                $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
                [void]$right.Children.Add((ConvertTo-PanelElement (Get-PanelIconXaml 'refresh' 13 $t.textSecondary 2 'Margin="0,0,6,0" VerticalAlignment="Center"')))
                [void]$right.Children.Add((& $newText (T 'bt.scan.running') $t.textSecondary 12))
            }
            [void]$sections.Children.Add((& $newHeader (T 'bt.section.nearby') $(if ($state.Scan) { -1 } else { $near.Count }) $right))
            if ($state.Scan) {
                [void]$sections.Children.Add((& $newSweep))
            } elseif (-not $near.Count -and $state.Scanned) {
                [void]$sections.Children.Add((& $newNote 'bluetooth' (T 'bt.none_near') $t.muted))
            }
            foreach ($d in $near) {
                $type = & $typeOf $d
                $icon = $typeIcon[$type]
                if (-not $icon) { $icon = $typeIcon['other'] }
                $btn = & $newButton 'neutral' 'plug' (T 'bt.btn.pair') $pair $d
                $sub = "$(T "bt.type.$type")  $([char]0x00B7)  $([VivacBluetooth]::FormatAddress($d.Address))"
                [void]$sections.Children.Add((& $newCard (& $newRow $icon $d.Name $sub $t.textSecondary @($btn))))
            }
        } finally { $state.Painting = $false }
        # The design's focus ring sits on the one button that answers Enter.
        $first = $state.FirstPrimary
        if ($first) { [void]$window.Dispatcher.BeginInvoke([Action]{ [void][Windows.Input.Keyboard]::Focus($first) }.GetNewClosure()) }
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
