# The network, drawn by vivac: Wi-Fi and the wired adapters, in the palette,
# dropping from the bar's right end as the sound and Bluetooth panels do,
# instead of Windows' quick settings flyout (which went with the taskbar).
# The bar's network gauges open it.
#
# Wi-Fi goes through the Native Wifi API and the wired side through .NET
# (lib/VivacNetwork.cs): both answer in numbers, the same in every language,
# where netsh answers in the user's. The state is read on a worker thread and
# the panel polls for it, so the window opens at once and fills in; Windows is
# asked to scan as the panel opens, and the list is read again while it stays
# open.
#
# A new network's key goes straight into Windows' own profile store
# (WlanSetProfile), never into a file; a profile made here for a connection
# that then fails is removed again, so a mistyped key is not kept.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')

$script:AsTask = $null

function Import-VivacNetwork {
    if ('VivacNetwork' -as [type]) { return }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacNetwork.cs'))) -Language CSharp -ReferencedAssemblies System.Core
}

# ---------------------------------------------------------------- the logic

# What a network's DOT11_AUTH_ALGORITHM asks of the panel: 'open' and 'psk'
# and 'sae' it can join itself (with a key for the last two); 'other' (WEP,
# enterprise, OWE) is left to Windows' own dialog.
function Get-VivacWifiAuthKind([int]$Auth) {
    switch ($Auth) {
        1 { 'open' }
        4 { 'psk' }
        7 { 'psk' }
        9 { 'sae' }
        default { 'other' }
    }
}

# The security a row names: open, or the family of protection.
function Get-VivacWifiAuthLabel([int]$Auth) {
    switch ($Auth) {
        1 { '' }
        2 { 'WEP' }
        { $_ -in 3, 4, 5 } { 'WPA' }
        { $_ -in 6, 7 } { 'WPA2' }
        { $_ -in 8, 9, 11 } { 'WPA3' }
        10 { 'OWE' }
        default { '' }
    }
}

# Signal bars, as Windows draws them: Segoe Fluent Icons' Wifi1-3 and Wifi.
function Get-VivacWifiGlyph([int]$Signal) {
    if ($Signal -ge 75) { return 0xE701 }
    if ($Signal -ge 50) { return 0xE874 }
    if ($Signal -ge 25) { return 0xE873 }
    0xE872
}

function Format-VivacSpeed([long]$Mbps) {
    if ($Mbps -ge 1000) {
        $g = $Mbps / 1000
        if ($g -eq [Math]::Floor($g)) { return "$g Gbps" }
        return ('{0:0.#} Gbps' -f $g)
    }
    "$Mbps Mbps"
}

# A Windows WLAN profile for a network joined from the panel. The key is
# checked as Windows would: 8 to 63 characters, or 64 hexadecimal digits.
function New-VivacWifiProfileXml([string]$Ssid, [string]$Key = '', [int]$Auth = 7, [int]$Cipher = 4) {
    $kind = Get-VivacWifiAuthKind $Auth
    if ($kind -eq 'other') { throw "authentication $Auth is left to Windows" }
    $hex = -join @([Text.Encoding]::UTF8.GetBytes($Ssid) | ForEach-Object { $_.ToString('X2') })
    $name = [Security.SecurityElement]::Escape($Ssid)
    $security = '<authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>'
    if ($kind -ne 'open') {
        if (-not ($Key.Length -ge 8 -and $Key.Length -le 63) -and $Key -notmatch '^[0-9A-Fa-f]{64}$') { throw 'the key must be 8 to 63 characters' }
        $authName = 'WPA2PSK'
        if ($kind -eq 'sae') { $authName = 'WPA3SAE' } elseif ($Auth -eq 4) { $authName = 'WPAPSK' }
        $enc = 'AES'
        if ($Cipher -eq 2) { $enc = 'TKIP' }
        $keyType = 'passPhrase'
        if ($Key.Length -eq 64) { $keyType = 'networkKey' }
        $security = "<authEncryption><authentication>$authName</authentication><encryption>$enc</encryption><useOneX>false</useOneX></authEncryption>" +
            "<sharedKey><keyType>$keyType</keyType><protected>false</protected><keyMaterial>$([Security.SecurityElement]::Escape($Key))</keyMaterial></sharedKey>"
    }
    @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$name</name>
  <SSIDConfig><SSID><hex>$hex</hex><name>$name</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>$security</security></MSM>
</WLANProfile>
"@
}

# What the header says: the connections there are, in one line.
function Get-VivacNetworkSummary($State) {
    $parts = @()
    if ($State.Connected) { $parts += "Wi-Fi: $($State.Ssid) - $($State.Signal) %" }
    foreach ($a in @($State.Adapters | Where-Object { -not $_.Wifi -and $_.Up })) { $parts += "$($a.Name): $(Format-VivacSpeed $a.SpeedMbps)" }
    if (-not $parts.Count) { return (T 'net.offline') }
    $parts -join '   '
}

# WinRT's radio switch, the one Windows' quick settings use: it needs no
# elevation, where the Native Wifi API's does.
function Wait-VivacNetWinRt($Operation, [type]$Type) {
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

function Set-VivacWifiRadio([bool]$On) {
    $null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
    $radios = Wait-VivacNetWinRt ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    $radio = $radios | Where-Object { [string]$_.Kind -eq 'WiFi' } | Select-Object -First 1
    if (-not $radio) { return $false }
    $access = Wait-VivacNetWinRt ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])
    if ([string]$access -ne 'Allowed') { return $false }
    $state = if ($On) { [Windows.Devices.Radios.RadioState]::On } else { [Windows.Devices.Radios.RadioState]::Off }
    [string](Wait-VivacNetWinRt ($radio.SetStateAsync($state)) ([Windows.Devices.Radios.RadioAccessStatus])) -eq 'Allowed'
}

# ---------------------------------------------------------------- the panel

function Show-Network([switch]$NoShow, [hashtable]$Registry, [ValidateSet('wifi', 'ethernet')][string]$Tab = 'wifi') {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'network' }
    Import-VivacNetwork
    $p = Get-Palette
    # The kit's icon font (lib/Surfaces.psm1, $script:KitIconFont).
    $icon = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $hints = @(@('&#x2191;&#x2193;', (T 'net.key.move')), @('&#x21B5;', (T 'net.key.connect')), @('Tab', (T 'net.key.tab')),
        @('F5', (T 'net.key.scan')), @('Esc', (T 'net.key.close')))
    $body = @"
<StackPanel>
  <Grid Margin="0,0,0,12">
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Border x:Name="TabWifi" CornerRadius="8" Padding="0,7" Cursor="Hand">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
        <TextBlock x:Name="TabWifiGlyph" Text="&#xE701;" FontFamily="$icon" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock x:Name="TabWifiText" Text="Wi-Fi" FontSize="13" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    <Border x:Name="TabEth" Grid.Column="2" CornerRadius="8" Padding="0,7" Cursor="Hand">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
        <TextBlock x:Name="TabEthGlyph" Text="&#xE839;" FontFamily="$icon" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock x:Name="TabEthText" Text="Ethernet" FontSize="13" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
  </Grid>

  <StackPanel x:Name="WifiPane">
    <Border Style="{StaticResource KitCard}" Padding="10,6"><ContentControl x:Name="RadioRow"/></Border>
    <Border x:Name="Current" Style="{StaticResource KitCard}" Visibility="Collapsed">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Width="44" Height="44" CornerRadius="22" Background="#$($p['COLOR_ACCENT'])">
            <TextBlock x:Name="CurGlyph" FontFamily="$icon" FontSize="20" Foreground="#$($p['COLOR_BG'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="CurSsid" FontSize="16" FontWeight="SemiBold" Foreground="#$($p['COLOR_FG'])" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="CurState" FontSize="11" Foreground="#$($p['COLOR_OK'])"/>
          </StackPanel>
        </Grid>
        <UniformGrid x:Name="CurStats" Columns="2" Margin="0,12,0,0"/>
        <UniformGrid Columns="3" Margin="0,10,0,0">
          <Button x:Name="Disconnect" Style="{StaticResource KitGhost}" Margin="0,0,4,0"/>
          <Button x:Name="ForgetCur" Style="{StaticResource KitGhost}" Margin="4,0,4,0"/>
          <Button x:Name="WifiSettings" Style="{StaticResource KitGhost}" Margin="4,0,0,0"/>
        </UniformGrid>
      </StackPanel>
    </Border>
    <Grid Margin="4,4,4,6">
      <TextBlock x:Name="NetsTitle" FontSize="11" FontWeight="SemiBold" Foreground="#$($p['COLOR_ACCENT'])"/>
      <TextBlock x:Name="NetsNote" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" HorizontalAlignment="Right"/>
    </Grid>
    <ListBox x:Name="Nets" Background="Transparent" BorderThickness="0" Focusable="False" MaxHeight="300"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
    <Border x:Name="Ask" Style="{StaticResource KitCard}" Margin="0,8,0,0" Visibility="Collapsed" BorderBrush="#$($p['COLOR_ACCENT'])" BorderThickness="1">
      <StackPanel>
        <TextBlock x:Name="AskTitle" FontSize="13" Foreground="#$($p['COLOR_FG'])" TextTrimming="CharacterEllipsis"/>
        <Border Background="#$($p['COLOR_BG'])" CornerRadius="8" Padding="10,7" Margin="0,8,0,0">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="&#xE8D7;" FontFamily="$icon" FontSize="14" Foreground="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <PasswordBox x:Name="Key" Grid.Column="1" Background="Transparent" BorderThickness="0" FontSize="14"
                         Foreground="#$($p['COLOR_FG'])" CaretBrush="#$($p['COLOR_ACCENT'])"/>
          </Grid>
        </Border>
        <TextBlock x:Name="AskError" FontSize="11" Foreground="#$($p['COLOR_URGENT'])" Margin="2,6,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
        <WrapPanel Margin="0,10,0,0">
          <Button x:Name="AskGo" Style="{StaticResource KitButton}" Margin="0,0,8,0"/>
          <Button x:Name="AskCancel" Style="{StaticResource KitGhost}"/>
        </WrapPanel>
      </StackPanel>
    </Border>
  </StackPanel>

  <StackPanel x:Name="EthPane" Visibility="Collapsed">
    <StackPanel x:Name="Adapters"/>
    <WrapPanel Margin="0,2,0,0">
      <Button x:Name="NetSettings" Style="{StaticResource KitGhost}" Margin="0,0,8,0"/>
      <Button x:Name="Ncpa" Style="{StaticResource KitGhost}"/>
    </WrapPanel>
  </StackPanel>
</StackPanel>
"@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - network' 470 300 (Get-KitPanelXaml $p 0xE701 (T 'net.title') $body $hints))
    Set-KitDropDown $window
    $f = @{}
    foreach ($n in 'Subtitle', 'HeaderRight', 'TabWifi', 'TabEth', 'TabWifiGlyph', 'TabWifiText', 'TabEthGlyph', 'TabEthText', 'WifiPane', 'EthPane',
        'RadioRow', 'Current', 'CurGlyph', 'CurSsid', 'CurState', 'CurStats', 'Disconnect', 'ForgetCur', 'WifiSettings', 'NetsTitle', 'NetsNote',
        'Nets', 'Ask', 'AskTitle', 'Key', 'AskError', 'AskGo', 'AskCancel', 'Adapters', 'NetSettings', 'Ncpa') {
        $f[$n] = $window.FindName($n)
    }
    $f.Subtitle.Text = T 'net.reading'
    $f.Disconnect.Content = T 'net.disconnect'
    $f.ForgetCur.Content = T 'net.forget'
    $f.WifiSettings.Content = T 'net.wifi_settings'
    $f.AskGo.Content = T 'net.connect'
    $f.AskCancel.Content = T 'net.cancel'
    $f.NetSettings.Content = T 'net.settings'
    $f.Ncpa.Content = T 'net.adapters'
    $f.NetsTitle.Text = (T 'net.available').ToUpper()

    # The rescan button in the header.
    $scanBtn = New-Object Windows.Controls.Button
    $scanBtn.Style = $window.Content.Child.Resources['KitGhost']
    $scanBtn.Padding = '0'
    $scanText = New-Object Windows.Controls.TextBlock
    $scanText.Text = Get-KitGlyph 0xE72C; $scanText.FontFamily = $icon; $scanText.FontSize = 13
    $scanBtn.Content = $scanText
    $scanBtn.ToolTip = T 'net.key.scan'
    [void]$f.HeaderRight.Children.Add($scanBtn)

    # The radio switch, in a row of its own.
    $radio = New-Object Windows.Controls.Primitives.ToggleButton
    $radio.Style = $window.Content.Child.Resources['KitSwitch']
    $radioRow = New-KitRow $p 0xE701 'Wi-Fi' '' $radio
    $f.RadioRow.Content = $radioRow

    $st = @{ State = $null; Task = $null; Scan = $null; Tab = $Tab; Ticks = 0; Next = 0; Pending = $null; AskNet = $null
        ForgetArmed = $false; Updating = $false; Busy = $false }

    $setTab = {
        param([string]$To)
        $st.Tab = $To
        $on = @{ Bg = "#$($p['COLOR_ACCENT'])"; Fg = "#$($p['COLOR_BG'])" }
        $off = @{ Bg = "#$($p['COLOR_SURFACE'])"; Fg = "#$($p['COLOR_FG'])" }
        $w = $off; $e = $off
        if ($To -eq 'wifi') { $w = $on } else { $e = $on }
        $f.TabWifi.Background = $w.Bg; $f.TabWifiGlyph.Foreground = $w.Fg; $f.TabWifiText.Foreground = $w.Fg
        $f.TabEth.Background = $e.Bg; $f.TabEthGlyph.Foreground = $e.Fg; $f.TabEthText.Foreground = $e.Fg
        $f.WifiPane.Visibility = if ($To -eq 'wifi') { 'Visible' } else { 'Collapsed' }
        $f.EthPane.Visibility = if ($To -eq 'ethernet') { 'Visible' } else { 'Collapsed' }
    }

    $newStat = {
        param([int]$Glyph, [string]$Label, [string]$Value)
        $g = New-Object Windows.Controls.StackPanel
        $g.Orientation = 'Horizontal'; $g.Margin = '0,4,8,4'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = Get-KitGlyph $Glyph; $t.FontFamily = $icon; $t.FontSize = 13; $t.Foreground = "#$($p['COLOR_ACCENT'])"
        $t.VerticalAlignment = 'Center'; $t.Margin = '0,0,8,0'
        [void]$g.Children.Add($t)
        $s = New-Object Windows.Controls.StackPanel
        $l = New-Object Windows.Controls.TextBlock
        $l.Text = $Label; $l.FontSize = 10; $l.Foreground = "#$($p['COLOR_MUTED'])"
        $v = New-Object Windows.Controls.TextBlock
        $v.Text = $Value; $v.FontSize = 12; $v.Foreground = "#$($p['COLOR_FG'])"; $v.TextTrimming = 'CharacterEllipsis'
        [void]$s.Children.Add($l); [void]$s.Children.Add($v)
        [void]$g.Children.Add($s)
        $g
    }

    $newButton = {
        param([string]$Text, [scriptblock]$Click, [string]$Style = 'KitGhost')
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.Content.Child.Resources[$Style]
        $b.Content = $Text; $b.Margin = '0,0,8,0'
        $b.Add_Click($Click)
        $b
    }

    $wifiAdapter = {
        if (-not $st.State) { return $null }
        $st.State.Adapters | Where-Object { $_.Wifi } | Select-Object -First 1
    }

    $renderWifi = {
        $s = $st.State
        $hasIf = $s -and $s.HasInterface
        $radio.IsEnabled = $hasIf -and -not $s.HardwareOff
        $st.Updating = $true
        $radio.IsChecked = $hasIf -and $s.RadioOn
        $st.Updating = $false
        $sub = T 'net.radio_on'
        if (-not $hasIf) { $sub = T 'net.no_wifi' }
        elseif ($s.HardwareOff) { $sub = T 'net.radio_hard_off' }
        elseif (-not $s.RadioOn) { $sub = T 'net.radio_off' }
        $radioRow.Tag.Sub.Text = $sub; $radioRow.Tag.Sub.Visibility = 'Visible'

        # The network in use.
        if ($hasIf -and $s.Connected) {
            $f.Current.Visibility = 'Visible'
            $f.CurGlyph.Text = Get-KitGlyph (Get-VivacWifiGlyph $s.Signal)
            $f.CurSsid.Text = $s.Ssid
            $secured = Get-VivacWifiAuthLabel $s.Auth
            $line = T 'net.connected'
            if ($secured) { $line += " - $secured" }
            $f.CurState.Text = $line
            $f.CurStats.Children.Clear()
            $band = $s.Band
            if ($s.Channel) { $band = (T 'net.band_channel' @($s.Band, [string]$s.Channel)) }
            $ip = ''
            $a = & $wifiAdapter
            if ($a -and $a.Ipv4.Count) { $ip = $a.Ipv4[0] }
            [void]$f.CurStats.Children.Add((& $newStat (Get-VivacWifiGlyph $s.Signal) (T 'net.signal') "$($s.Signal) %  ($($s.Rssi) dBm)"))
            [void]$f.CurStats.Children.Add((& $newStat 0xEC05 (T 'net.band') $band))
            [void]$f.CurStats.Children.Add((& $newStat 0xEC4A (T 'net.speed') (Format-VivacSpeed ([Math]::Max($s.RxMbps, $s.TxMbps)))))
            [void]$f.CurStats.Children.Add((& $newStat 0xE968 'IP' $ip))
            if (-not $st.ForgetArmed) { $f.ForgetCur.Content = T 'net.forget' }
        } else {
            $f.Current.Visibility = 'Collapsed'
        }

        # The others in range, strongest first; the selection is kept by name.
        $keep = $null
        if ($f.Nets.SelectedItem) { $keep = $f.Nets.SelectedItem.Tag.Net.Ssid }
        $f.Nets.Items.Clear()
        $nets = @()
        if ($hasIf -and $s.RadioOn) { $nets = @($s.Networks | Where-Object { -not $_.Connected }) }
        foreach ($n in $nets) {
            $bits = @()
            $label = Get-VivacWifiAuthLabel $n.Auth
            if ($n.Secured) { $bits += (T 'net.secured' @($label)).Trim() } else { $bits += T 'net.open' }
            if ($n.Known) { $bits += T 'net.known' }
            if ($st.Pending -and $st.Pending.Ssid -eq $n.Ssid) { $bits = @(T 'net.connecting') }
            $right = New-Object Windows.Controls.StackPanel
            $right.Orientation = 'Horizontal'
            $pct = New-Object Windows.Controls.TextBlock
            $pct.Text = "$($n.Signal) %"; $pct.FontSize = 11; $pct.Foreground = "#$($p['COLOR_MUTED'])"
            $pct.VerticalAlignment = 'Center'; $pct.Margin = '0,0,10,0'
            [void]$right.Children.Add($pct)
            $lock = New-Object Windows.Controls.TextBlock
            $lock.FontFamily = $icon; $lock.FontSize = 13; $lock.Foreground = "#$($p['COLOR_MUTED'])"; $lock.VerticalAlignment = 'Center'
            $lock.Text = if ($n.Secured) { Get-KitGlyph 0xE72E } else { Get-KitGlyph 0xE785 }
            [void]$right.Children.Add($lock)
            $color = $p['COLOR_ACCENT']
            if ($n.Signal -lt 35) { $color = $p['COLOR_MUTED'] }
            $row = New-KitRow $p (Get-VivacWifiGlyph $n.Signal) $n.Ssid ($bits -join ' - ') $right $color
            $row.Tag.Net = $n
            if ($n.Known) { $row.ToolTip = T 'net.forget_hint' }
            [void]$f.Nets.Items.Add($row)
            if ($keep -and $n.Ssid -eq $keep) { $f.Nets.SelectedItem = $row }
        }
        if (-not $f.Nets.SelectedItem -and $f.Nets.Items.Count) { $f.Nets.SelectedIndex = 0 }
        $note = ''
        if (-not $hasIf) { $note = '' }
        elseif (-not $s.RadioOn) { $note = T 'net.radio_off' }
        elseif (-not $nets.Count) { $note = T 'net.searching' }
        else { $note = T 'net.count' @([string]$nets.Count) }
        $f.NetsNote.Text = $note
    }

    $renderEth = {
        $f.Adapters.Children.Clear()
        $wired = @()
        if ($st.State) { $wired = @($st.State.Adapters | Where-Object { -not $_.Wifi }) }
        if (-not $wired.Count) {
            $none = New-Object Windows.Controls.TextBlock
            $none.Text = T 'net.no_wired'; $none.Foreground = "#$($p['COLOR_MUTED'])"; $none.Margin = '4,0,0,12'
            [void]$f.Adapters.Children.Add($none)
            return
        }
        foreach ($a in $wired) {
            $card = New-Object Windows.Controls.Border
            $card.Style = $window.Content.Child.Resources['KitCard']
            $stack = New-Object Windows.Controls.StackPanel
            $state = T 'net.cable_out'
            $color = $p['COLOR_MUTED']
            if ($a.Up) {
                $state = "$(T 'net.connected') - $(Format-VivacSpeed $a.SpeedMbps)"
                $color = $p['COLOR_ACCENT']
            }
            $row = New-KitRow $p 0xE839 $a.Name $state $null $color
            if ($a.Up) { $row.Tag.Sub.Foreground = "#$($p['COLOR_OK'])" }
            [void]$stack.Children.Add($row)
            $desc = New-Object Windows.Controls.TextBlock
            $desc.Text = $a.Description; $desc.FontSize = 11; $desc.Foreground = "#$($p['COLOR_MUTED'])"
            $desc.Margin = '52,0,0,6'; $desc.TextTrimming = 'CharacterEllipsis'
            [void]$stack.Children.Add($desc)
            if ($a.Up) {
                $grid = New-Object Windows.Controls.Primitives.UniformGrid
                $grid.Columns = 2
                $v4 = ($a.Ipv4 -join ', '); if (-not $v4) { $v4 = '-' }
                $gw = ($a.Gateways -join ', '); if (-not $gw) { $gw = '-' }
                $dns = (@($a.Dns | Select-Object -First 2) -join ', '); if (-not $dns) { $dns = '-' }
                $mode = if ($a.Dhcp) { 'DHCP' } else { T 'net.static' }
                [void]$grid.Children.Add((& $newStat 0xE968 'IPv4' "$v4"))
                [void]$grid.Children.Add((& $newStat 0xE80F (T 'net.gateway') $gw))
                [void]$grid.Children.Add((& $newStat 0xE774 'DNS' $dns))
                [void]$grid.Children.Add((& $newStat 0xE713 (T 'net.mode') $mode))
                [void]$stack.Children.Add($grid)
                if ($a.Ipv6.Count) {
                    [void]$stack.Children.Add((& $newStat 0xE968 'IPv6' ($a.Ipv6[0])))
                }
            }
            [void]$stack.Children.Add((& $newStat 0xE8EC 'MAC' $a.Mac))
            $buttons = New-Object Windows.Controls.WrapPanel
            $buttons.Margin = '0,8,0,0'
            if ($a.Up -and $a.Ipv4.Count) {
                $ipText = $a.Ipv4[0]
                $copy = & $newButton (T 'net.copy_ip') { param($s) Set-Clipboard -Value $s.Tag; $s.Content = T 'net.copied' }
                $copy.Tag = $ipText
                [void]$buttons.Children.Add($copy)
            }
            if ($a.Up -and $a.Dhcp) {
                # Renewing the lease takes an administrator; Windows asks.
                $renew = & $newButton (T 'net.renew') {
                    param($s)
                    try { Start-Process ipconfig.exe -ArgumentList '/renew', "`"$($s.Tag)`"" -Verb RunAs -WindowStyle Hidden } catch { }
                }
                $renew.Tag = $a.Name
                [void]$buttons.Children.Add($renew)
            }
            [void]$stack.Children.Add($buttons)
            $card.Child = $stack
            [void]$f.Adapters.Children.Add($card)
        }
    }

    $render = {
        if ($st.State) { $f.Subtitle.Text = Get-VivacNetworkSummary $st.State }
        & $renderWifi
        & $renderEth
    }

    # A fresh read on a worker thread; the timer picks it up.
    $refresh = { if (-not $st.Task) { $st.Task = [VivacNetwork]::GetStateAsync() } }
    $scan = {
        if ($st.State -and $st.State.HasInterface -and $st.State.RadioOn) {
            $st.Scan = [VivacNetwork]::ScanAsync($st.State.Interface)
            $f.NetsNote.Text = T 'net.searching'
        }
        $st.Next = $st.Ticks + 8
    }

    $showAsk = {
        param($Net)
        $st.AskNet = $Net
        $f.AskTitle.Text = T 'net.key_for' @($Net.Ssid)
        $f.Key.Password = ''
        $f.AskError.Visibility = 'Collapsed'
        $f.Ask.Visibility = 'Visible'
        [void]$f.Key.Focus()
    }
    $hideAsk = { $st.AskNet = $null; $f.Ask.Visibility = 'Collapsed'; $f.Key.Password = '' }

    $connect = {
        param($Net)
        if (-not $Net -or $Net.Connected -or -not $st.State) { return }
        $guid = $st.State.Interface
        $kind = Get-VivacWifiAuthKind $Net.Auth
        if ($Net.Known) {
            [void][VivacNetwork]::Connect($guid, $Net.Profile)
            $st.Pending = @{ Ssid = $Net.Ssid; Created = $false; Until = $st.Ticks + 50 }
        } elseif ($kind -eq 'open') {
            if ([VivacNetwork]::SaveProfile($guid, (New-VivacWifiProfileXml $Net.Ssid '' 1)) -eq 0) {
                [void][VivacNetwork]::Connect($guid, $Net.Ssid)
                $st.Pending = @{ Ssid = $Net.Ssid; Created = $true; Until = $st.Ticks + 50 }
            }
        } elseif ($kind -eq 'other') {
            # Enterprise and older networks: Windows' own dialog asks for
            # what they need.
            $window.Close()
            Start-Process 'ms-availablenetworks:'
            return
        } else {
            & $showAsk $Net
            return
        }
        & $render
        $st.Next = $st.Ticks + 4
    }

    $connectWithKey = {
        $n = $st.AskNet
        if (-not $n) { return }
        try { $xml = New-VivacWifiProfileXml $n.Ssid $f.Key.Password $n.Auth $n.Cipher }
        catch { $f.AskError.Text = T 'net.key_invalid'; $f.AskError.Visibility = 'Visible'; return }
        $guid = $st.State.Interface
        $rc = [VivacNetwork]::SaveProfile($guid, $xml)
        if ($rc -ne 0) { $f.AskError.Text = T 'net.failed' @([string]$rc); $f.AskError.Visibility = 'Visible'; return }
        [void][VivacNetwork]::Connect($guid, $n.Ssid)
        $st.Pending = @{ Ssid = $n.Ssid; Created = $true; Until = $st.Ticks + 50 }
        & $hideAsk
        & $render
        $st.Next = $st.Ticks + 4
    }

    # A connection asked for is watched until it holds, or for about twelve
    # seconds; a profile made here for one that never held goes again.
    $watchPending = {
        $pend = $st.Pending
        if (-not $pend -or -not $st.State) { return }
        if ($st.State.Connected -and $st.State.Ssid -eq $pend.Ssid) { $st.Pending = $null; return }
        if ($st.Ticks -ge $pend.Until) {
            $st.Pending = $null
            if ($pend.Created) { try { [void][VivacNetwork]::Forget($st.State.Interface, $pend.Ssid) } catch { } }
            $net = $st.State.Networks | Where-Object { $_.Ssid -eq $pend.Ssid } | Select-Object -First 1
            if ($net -and $pend.Created -and (Get-VivacWifiAuthKind $net.Auth) -ne 'open') {
                & $showAsk $net
                $f.AskError.Text = T 'net.wrong_key'; $f.AskError.Visibility = 'Visible'
            } else {
                $f.NetsNote.Text = T 'net.not_joined' @($pend.Ssid)
            }
        }
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
            $st.Ticks++
            if ($st.Task -and $st.Task.IsCompleted) {
                $t = $st.Task; $st.Task = $null
                if (-not $t.IsFaulted) {
                    $first = -not $st.State
                    $st.State = $t.Result
                    & $watchPending
                    # Rebuilding the list under the pointer or the key box
                    # would only get in the way: the rows wait for them.
                    if ($first -or -not $f.Nets.IsMouseOver) { & $render } else { $f.Subtitle.Text = Get-VivacNetworkSummary $st.State }
                    if ($first) { & $scan }
                }
            }
            if ($st.Scan -and $st.Scan.IsCompleted) { $st.Scan = $null; $st.Next = $st.Ticks + 10 }
            if ($st.Ticks -ge $st.Next -and -not $st.Task) {
                & $refresh
                $st.Next = $st.Ticks + 16
                if ($st.Pending) { $st.Next = $st.Ticks + 4 }
            }
        })

    $radio.Add_Click({
            if ($st.Updating) { return }
            $want = [bool]$radio.IsChecked
            $ok = $false
            try { $ok = Set-VivacWifiRadio $want } catch { }
            if (-not $ok) { $st.Updating = $true; $radio.IsChecked = -not $want; $st.Updating = $false }
            $st.Next = $st.Ticks + 6
        })
    $f.Disconnect.Add_Click({
            if ($st.State) { [void][VivacNetwork]::Disconnect($st.State.Interface) }
            $st.Next = $st.Ticks + 3
        })
    # Forgetting asks twice, as ending the session does.
    $f.ForgetCur.Add_Click({
            if (-not $st.State) { return }
            if (-not $st.ForgetArmed) {
                $st.ForgetArmed = $true
                $f.ForgetCur.Content = T 'net.forget_confirm'
                $f.ForgetCur.Foreground = "#$($p['COLOR_URGENT'])"
                return
            }
            $st.ForgetArmed = $false
            $f.ForgetCur.Foreground = "#$($p['COLOR_FG'])"
            [void][VivacNetwork]::Forget($st.State.Interface, $st.State.Profile)
            $st.Next = $st.Ticks + 3
        })
    $f.WifiSettings.Add_Click({ $window.Close(); Start-Process 'ms-settings:network-wifi' })
    $f.NetSettings.Add_Click({ $window.Close(); Start-Process 'ms-settings:network' })
    $f.Ncpa.Add_Click({ $window.Close(); Start-Process 'ncpa.cpl' })
    $f.AskGo.Add_Click({ & $connectWithKey })
    $f.AskCancel.Add_Click({ & $hideAsk })
    $scanBtn.Add_Click({ & $scan })
    $f.TabWifi.Add_MouseLeftButtonUp({ & $setTab 'wifi' })
    $f.TabEth.Add_MouseLeftButtonUp({ & $setTab 'ethernet' })

    # A click on a network joins it; a right click on a known one forgets it,
    # after a second right click.
    $f.Nets.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $item = [Windows.Controls.ItemsControl]::ContainerFromElement($f.Nets, $e.OriginalSource)
            if ($item -is [Windows.Controls.ListBoxItem]) { & $connect $item.Content.Tag.Net }
        })
    $f.Nets.Add_PreviewMouseRightButtonUp({
            param($s, $e)
            $item = [Windows.Controls.ItemsControl]::ContainerFromElement($f.Nets, $e.OriginalSource)
            if (-not ($item -is [Windows.Controls.ListBoxItem])) { return }
            $row = $item.Content
            $n = $row.Tag.Net
            if (-not $n.Known) { return }
            if ($row.Tag['Armed']) {
                [void][VivacNetwork]::Forget($st.State.Interface, $n.Profile)
                $st.Next = $st.Ticks + 2
            } else {
                $row.Tag['Armed'] = $true
                $row.Tag.Sub.Text = T 'net.forget_confirm'
                $row.Tag.Sub.Foreground = "#$($p['COLOR_URGENT'])"
            }
            $e.Handled = $true
        })

    $window.Add_PreviewKeyDown({
            param($s, $e)
            $k = [string]$e.Key
            if ($k -eq 'Escape') {
                if ($st.AskNet) { & $hideAsk } else { $window.Close() }
                $e.Handled = $true; return
            }
            if ($k -eq 'Tab') { if ($st.Tab -eq 'wifi') { & $setTab 'ethernet' } else { & $setTab 'wifi' }; $e.Handled = $true; return }
            if ($k -eq 'F5') { & $scan; $e.Handled = $true; return }
            if ($st.AskNet) {
                if ($k -eq 'Return') { & $connectWithKey; $e.Handled = $true }
                return
            }
            if ($st.Tab -ne 'wifi') { return }
            $n = $f.Nets.Items.Count
            if ($k -eq 'Down' -and $n) { $f.Nets.SelectedIndex = [Math]::Min($n - 1, $f.Nets.SelectedIndex + 1); $f.Nets.ScrollIntoView($f.Nets.SelectedItem); $e.Handled = $true; return }
            if ($k -eq 'Up' -and $n) { $f.Nets.SelectedIndex = [Math]::Max(0, $f.Nets.SelectedIndex - 1); $f.Nets.ScrollIntoView($f.Nets.SelectedItem); $e.Handled = $true; return }
            if ($k -eq 'Return' -and $f.Nets.SelectedItem) { & $connect $f.Nets.SelectedItem.Tag.Net; $e.Handled = $true; return }
        })

    & $setTab $Tab
    & $renderWifi
    & $renderEth
    # On the window itself: the handler outlives this function's variables
    # when the window is only built (-NoShow) and closed later.
    $window.Tag = $timer
    $window.Add_Closed({ param($s) if ($s.Tag) { $s.Tag.Stop() } })
    if ($NoShow) { return $window }
    & $refresh
    $timer.Start()
    if ($Registry) { $Registry['network'] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Network, Import-VivacNetwork, Get-VivacWifiAuthKind, Get-VivacWifiAuthLabel, Get-VivacWifiGlyph,
    Format-VivacSpeed, New-VivacWifiProfileXml, Get-VivacNetworkSummary, Set-VivacWifiRadio
