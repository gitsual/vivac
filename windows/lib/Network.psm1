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
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetIcons.psm1')

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

function ConvertTo-NetXml([string]$s) { [Security.SecurityElement]::Escape($s) }

# The Wi-Fi adapters the machine has, as the state names them: the one that
# carries the connection is the one the Native Wifi state was read from. Only
# a machine with two (an internal card and a USB stick) has anything to tell.
function Get-VivacWifiAdapters($State) {
    $out = @()
    if (-not $State) { return $out }
    $wifi = @($State.Adapters | Where-Object { $_.Wifi })
    if ($wifi.Count -lt 2) { return $out }
    $guid = ''
    if ($State.HasInterface) { $guid = ([string]$State.Interface).Trim('{}').ToLowerInvariant() }
    foreach ($a in $wifi) {
        $id = ([string]$a.Id).Trim('{}').ToLowerInvariant()
        $out += [pscustomobject]@{ Name = $a.Name; Description = $a.Description; Up = [bool]$a.Up; Carries = ($id -eq $guid) }
    }
    $out
}

# The samples a sparkline draws, as points in a box W x H: the lowest and the
# highest sample at the box's bottom and top margins, a flat series in the
# middle. One sample is drawn as a flat line.
function Get-VivacSparkPoints([double[]]$Values, [double]$W, [double]$H) {
    $v = @($Values)
    if (-not $v.Count) { return @() }
    if ($v.Count -eq 1) { $v = @($v[0], $v[0]) }
    $lo = ($v | Measure-Object -Minimum).Minimum
    $hi = ($v | Measure-Object -Maximum).Maximum
    $top = 6.0; $bottom = $H - 3
    $pts = @()
    for ($i = 0; $i -lt $v.Count; $i++) {
        $x = $W * $i / ($v.Count - 1)
        $y = ($top + $bottom) / 2
        if ($hi -gt $lo) { $y = $bottom - ($v[$i] - $lo) / ($hi - $lo) * ($bottom - $top) }
        $pts += [pscustomobject]@{ X = $x; Y = $y }
    }
    $pts
}

function Show-Network([switch]$NoShow, [hashtable]$Registry, [ValidateSet('wifi', 'ethernet')][string]$Tab = 'wifi') {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'network' }
    Import-VivacNetwork
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $hints = @(@(([string][char]0x2191 + [char]0x2193), (T 'net.key.move')), @([string][char]0x21B5, (T 'net.key.connect')),
        @('F5', (T 'net.key.scan')), @('Esc', (T 'net.key.close')))
    $area = ConvertTo-PanelMix $t.surface $t.accent 0.22
    $ic = { param([string]$n, [double]$s, [string]$c, [string]$x = '') Get-NetIconXaml $n $s $c 2 $x }
    $inline = { param([string]$x) ConvertTo-PanelElement $x }
    $brush = { param([string]$h) (New-Object Windows.Media.BrushConverter).ConvertFromString("#$h") }

    $body = @"
<Grid>
  <DockPanel>
    <Grid DockPanel.Dock="Top" Margin="2,0,2,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Width="36" Height="36" CornerRadius="10" Background="#$($t.surface)"><Grid HorizontalAlignment="Center" VerticalAlignment="Center">$(Get-NetIconXaml 'wifi' 18 $t.accent)</Grid></Border>
      <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
        <TextBlock Text="$(ConvertTo-NetXml (T 'net.title'))" FontSize="15" FontWeight="Bold" Foreground="#$($t.text)"/>
        <TextBlock x:Name="Subtitle" FontSize="12" Foreground="#$($t.textSecondary)" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <Grid x:Name="HeaderRight" Grid.Column="2">$(Get-NetButtonXaml $t 'Scan' '' 'refresh' 'neutral' 36 'Width="36"')</Grid>
    </Grid>
    <Border x:Name="Foot" DockPanel.Dock="Bottom" Margin="0,10,0,0" Padding="2,8,0,0" BorderBrush="#$($t.line)" BorderThickness="0,1,0,0">$(Get-KitHintsXamlV2 $t $hints)</Border>
    <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>
      <Border Background="#$($t.surface)" CornerRadius="12" Padding="4" Margin="0,0,0,12">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="4"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Border x:Name="TabWifi" CornerRadius="9" Padding="0,8" Cursor="Hand" Background="Transparent"><ContentControl x:Name="TabWifiBody" HorizontalAlignment="Center"/></Border>
          <Border x:Name="TabEth" Grid.Column="2" CornerRadius="9" Padding="0,8" Cursor="Hand" Background="Transparent"><ContentControl x:Name="TabEthBody" HorizontalAlignment="Center"/></Border>
        </Grid>
      </Border>

      <StackPanel x:Name="WifiPane">
        <Border Background="#$($t.surface)" CornerRadius="12" Padding="14" Margin="0,0,0,12">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              $(Get-NetTileXaml $t 'wifi' 40)
              <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
                <TextBlock x:Name="CurSsid" FontSize="16" FontWeight="Bold" Foreground="#$($t.text)" TextTrimming="CharacterEllipsis"/>
                <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                  <ContentControl x:Name="CurCheck" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="CurState" FontSize="12" Foreground="#$($t.textSecondary)" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
              </StackPanel>
              $(Get-NetSwitchXaml $t 'Radio' 'Grid.Column="2"')
            </Grid>
            <StackPanel x:Name="ConnDetail">
              <Grid Margin="0,12,0,0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                  <TextBlock x:Name="SpeedNum" FontSize="28" FontWeight="Bold" Foreground="#$($t.text)"/>
                  <TextBlock x:Name="SpeedUnit" FontSize="13" Foreground="#$($t.muted)" Margin="6,0,0,5" VerticalAlignment="Bottom"/>
                </StackPanel>
                <TextBlock Text="$(ConvertTo-NetXml (T 'net.last_2min'))" FontSize="11" Foreground="#$($t.muted)" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
              </Grid>
              <Border x:Name="SparkBox" Height="44" Margin="0,6,0,10" ClipToBounds="True" CornerRadius="4">
                <Canvas x:Name="Spark">
                  <Polygon x:Name="SparkArea" Fill="#$area"/>
                  <Polyline x:Name="SparkLine" Stroke="#$($t.accent)" StrokeThickness="1.6" StrokeLineJoin="Round"/>
                </Canvas>
              </Border>
              <UniformGrid x:Name="CurStats" Columns="2" Margin="-3,0,-3,4"/>
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
                $(Get-NetButtonXaml $t 'Disconnect' (T 'net.disconnect') '' 'neutral' 34 'Grid.Column="0"')
                $(Get-NetButtonXaml $t 'ForgetCur' (T 'net.forget') '' 'neutral' 34 'Grid.Column="2"')
                $(Get-NetButtonXaml $t 'WifiSettings' (T 'net.wifi_settings') '' 'neutral' 34 'Grid.Column="4"')
              </Grid>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border x:Name="WifiCards" Background="#$($t.surface)" CornerRadius="12" Padding="12,10" Margin="0,0,0,12" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="$(ConvertTo-NetXml ((T 'net.wifi_adapters').ToUpper()))" FontSize="12" FontWeight="Bold" Foreground="#$($t.muted)" Margin="0,0,0,6"/>
            <StackPanel x:Name="WifiCardRows"/>
          </StackPanel>
        </Border>
        <DockPanel Margin="2,0,0,8" Height="20">
          <TextBlock x:Name="NetsNote" DockPanel.Dock="Right" FontSize="12" Foreground="#$($t.textSecondary)" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="NetsTitle" FontSize="12" FontWeight="Bold" Foreground="#$($t.muted)" VerticalAlignment="Center"/>
            <Border x:Name="NetsPill" Background="#$($t.surface)" CornerRadius="8" Padding="7,1" Margin="8,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"><TextBlock x:Name="NetsCount" FontSize="12" Foreground="#$($t.text)"/></Border>
          </StackPanel>
        </DockPanel>
        <StackPanel x:Name="Nets"/>
        <Border x:Name="Ask" Background="#$($t.surface)" CornerRadius="12" Padding="12" Margin="0,4,0,0" Visibility="Collapsed" BorderBrush="#$($t.accent)" BorderThickness="1">
          <StackPanel>
            <TextBlock x:Name="AskTitle" FontSize="13" FontWeight="Bold" Foreground="#$($t.text)" TextTrimming="CharacterEllipsis"/>
            <Border Background="#$($t.bg)" CornerRadius="10" Padding="10,8" Margin="0,8,0,0">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid VerticalAlignment="Center" Margin="0,0,10,0">$(Get-NetIconXaml 'lock' 14 $t.accent)</Grid>
                <PasswordBox x:Name="Key" Grid.Column="1" Background="Transparent" BorderThickness="0" FontSize="14" Foreground="#$($t.text)" CaretBrush="#$($t.accent)"/>
              </Grid>
            </Border>
            <TextBlock x:Name="AskError" FontSize="11" Foreground="#$($t.alertText)" Margin="2,6,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <Grid Margin="0,0,8,0">$(Get-NetButtonXaml $t 'AskGo' (T 'net.connect') '' 'primary' 34)</Grid>
              $(Get-NetButtonXaml $t 'AskCancel' (T 'net.cancel') '' 'neutral' 34)
            </StackPanel>
          </StackPanel>
        </Border>
      </StackPanel>

      <StackPanel x:Name="EthPane" Visibility="Collapsed">
        <StackPanel x:Name="Adapters"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
          $(Get-NetButtonXaml $t 'NetSettings' (T 'net.settings') 'sliders' 'neutral' 34 'Grid.Column="0"')
          $(Get-NetButtonXaml $t 'Ncpa' (T 'net.adapters') 'plug' 'neutral' 34 'Grid.Column="2"')
        </Grid>
      </StackPanel>
    </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Grid>
"@
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - network' 470 $body)
    Add-KitDrawResources $window $p
    Set-KitDropDown $window
    $f = @{}
    foreach ($n in 'Subtitle', 'Scan', 'Scroll', 'TabWifi', 'TabEth', 'TabWifiBody', 'TabEthBody', 'WifiPane', 'EthPane', 'CurSsid', 'CurCheck', 'CurState',
        'Radio', 'ConnDetail', 'SpeedNum', 'SpeedUnit', 'SparkBox', 'Spark', 'SparkArea', 'SparkLine', 'CurStats', 'Disconnect', 'ForgetCur', 'WifiSettings',
        'WifiCards', 'WifiCardRows', 'NetsTitle', 'NetsPill', 'NetsCount', 'NetsNote', 'Nets', 'Ask', 'AskTitle', 'Key', 'AskError', 'AskGo', 'AskCancel',
        'Adapters', 'NetSettings', 'Ncpa') {
        $f[$n] = $window.FindName($n)
    }
    $f.Scroll.MaxHeight = [Math]::Max(300, $window.MaxHeight - 150)
    $f.Subtitle.Text = T 'net.reading'
    $f.NetsTitle.Text = (T 'net.available').ToUpper()
    $f.Scan.ToolTip = T 'net.key.scan'
    $radio = $f.Radio
    # The forget button is the alert's soft tone until it is armed.
    $softForget = {
        $f.ForgetCur.Background = & $brush $t.alertSoft
        $f.ForgetCur.Foreground = & $brush $t.alert
        Set-NetButtonText $f.ForgetCur (T 'net.forget')
    }
    & $softForget

    $st = @{ State = $null; Task = $null; Scan = $null; Tab = $Tab; Ticks = 0; Next = 0; Pending = $null; AskNet = $null
        ForgetArmed = $false; Updating = $false; Busy = $false; Sel = ''; Armed = ''; NetList = @(); History = (New-Object System.Collections.ArrayList) }

    # A tab's content: its icon and name (Ethernet adds the speed of the cable
    # in use), in the active tab's text colour or the quiet one.
    $drawTabs = {
        $speed = ''
        if ($st.State) {
            $w = @($st.State.Adapters | Where-Object { -not $_.Wifi -and $_.Up } | Select-Object -First 1)
            if ($w.Count) { $speed = Format-VivacSpeed $w[0].SpeedMbps }
        }
        foreach ($tab in @(@('wifi', 'wifi', 'Wi-Fi', ''), @('eth', 'ethernet', 'Ethernet', $speed))) {
            $on = ($st.Tab -eq 'wifi' -and $tab[0] -eq 'wifi') -or ($st.Tab -eq 'ethernet' -and $tab[0] -eq 'eth')
            $fg = $t.text; $fill = 'Transparent'
            if ($on) { $fg = $t.actionText; $fill = "#$($t.actionFill)" }
            $extra = ''
            if ($tab[3]) { $extra = "<TextBlock Text=`"$(ConvertTo-NetXml $tab[3])`" FontSize=`"11`" Foreground=`"#$(if ($on) { $fg } else { $t.muted })`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"/>" }
            $x = "<StackPanel Orientation=`"Horizontal`">$(Get-NetIconXaml $tab[1] 14 $fg 2 'Margin="0,0,8,0" VerticalAlignment="Center"')<TextBlock Text=`"$($tab[2])`" FontSize=`"13`" FontWeight=`"Bold`" Foreground=`"#$fg`" VerticalAlignment=`"Center`"/>$extra</StackPanel>"
            $tabHost = $f["Tab$(if ($tab[0] -eq 'wifi') { 'Wifi' } else { 'Eth' })"]
            $body2 = $f["Tab$(if ($tab[0] -eq 'wifi') { 'Wifi' } else { 'Eth' })Body"]
            $body2.Content = & $inline $x
            $tabHost.Background = & $brush $(if ($on) { $t.actionFill } else { $t.surface })
            if (-not $on) { $tabHost.Background = [Windows.Media.Brushes]::Transparent }
        }
    }

    $setTab = {
        param([string]$To)
        $st.Tab = $To
        $f.WifiPane.Visibility = if ($To -eq 'wifi') { 'Visible' } else { 'Collapsed' }
        $f.EthPane.Visibility = if ($To -eq 'ethernet') { 'Visible' } else { 'Collapsed' }
        & $drawTabs
    }

    # The last two minutes of the link's speed, drawn to the box's width.
    $drawSpark = {
        $w = $f.SparkBox.ActualWidth
        if (-not $w -or $w -lt 10) { $w = 400 }
        $pts = @(Get-VivacSparkPoints ([double[]]@($st.History)) $w 44)
        $line = New-Object Windows.Media.PointCollection
        $fill = New-Object Windows.Media.PointCollection
        if ($pts.Count) {
            foreach ($q in $pts) { $line.Add([Windows.Point]::new($q.X, $q.Y)) }
            $fill.Add([Windows.Point]::new(0, 44))
            foreach ($q in $pts) { $fill.Add([Windows.Point]::new($q.X, $q.Y)) }
            $fill.Add([Windows.Point]::new($w, 44))
        }
        $f.SparkLine.Points = $line
        $f.SparkArea.Points = $fill
    }

    $wifiAdapter = {
        if (-not $st.State) { return $null }
        $st.State.Adapters | Where-Object { $_.Wifi } | Select-Object -First 1
    }

    # One network of the list: the selected one in the accent, the rest on
    # the card colour. The net rides in the row's Tag for the handlers.
    $newNetRow = {
        param($n, [bool]$Selected, [bool]$Armed, [string]$Sub)
        $bg = $t.surface; $nameC = $t.text; $subC = $t.textSecondary; $tile = $t.surfaceAlt; $iconC = $t.accent; $barC = $t.accent; $pctC = $t.textSecondary
        if ($Selected) {
            $bg = $t.actionFill; $nameC = $t.actionText; $subC = ConvertTo-PanelMix $t.actionFill $t.actionText 0.62
            $tile = $t.actionText; $iconC = $t.actionFill; $barC = $t.actionText; $pctC = $t.actionText
        } elseif ($n.Signal -lt 35) { $barC = $t.muted }
        if ($Armed) { $subC = if ($Selected) { $t.actionText } else { $t.alertText } }
        $lockIcon = if ($n.Secured) { 'lock' } else { 'unlock' }
        $hover = ''
        if (-not $Selected) {
            $hover = "<Border.Style><Style TargetType=`"Border`"><Setter Property=`"Background`" Value=`"#$bg`"/><Style.Triggers><Trigger Property=`"IsMouseOver`" Value=`"True`"><Setter Property=`"Background`" Value=`"#$($t.neutralHover)`"/></Trigger></Style.Triggers></Style></Border.Style>"
            $bgAttr = ''
        } else { $bgAttr = "Background=`"#$bg`"" }
        $ssid = ConvertTo-NetXml $n.Ssid
        $subx = ConvertTo-NetXml $Sub
        $x = @"
<Border Cursor="Hand" CornerRadius="10" Padding="10,8" Margin="0,0,0,6" $bgAttr>$hover
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    $(Get-NetTileXaml $t 'wifi' 32 $tile $iconC)
    <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
      <TextBlock Text="$ssid" FontSize="13" FontWeight="Bold" Foreground="#$nameC" TextTrimming="CharacterEllipsis"/>
      <TextBlock Text="$subx" FontSize="11" Foreground="#$subC" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
      $(Get-NetBarsXaml $t $n.Signal $barC)
      <TextBlock Text="$($n.Signal) %" FontSize="12" Foreground="#$pctC" Margin="8,0,8,0" VerticalAlignment="Center"/>
      $(Get-NetIconXaml $lockIcon 13 $pctC 2 'VerticalAlignment="Center"')
    </StackPanel>
  </Grid>
</Border>
"@
        $row = & $inline $x
        $row.Tag = @{ Net = $n }
        if ($n.Known) { $row.ToolTip = T 'net.forget_hint' }
        $row
    }

    $renderNets = {
        param([bool]$Reveal = $false)
        $s = $st.State
        $hasIf = $s -and $s.HasInterface
        $nets = @()
        if ($hasIf -and $s.RadioOn) { $nets = @($s.Networks | Where-Object { -not $_.Connected }) }
        $st.NetList = $nets
        if (-not ($nets | Where-Object { $_.Ssid -eq $st.Sel })) { $st.Sel = ''; if ($nets.Count) { $st.Sel = $nets[0].Ssid } }
        $f.Nets.Children.Clear()
        $selRow = $null
        foreach ($n in $nets) {
            $bits = @()
            $label = Get-VivacWifiAuthLabel $n.Auth
            if ($n.Secured) { $bits += (T 'net.secured' @($label)).Trim() } else { $bits += T 'net.open' }
            if ($n.Known) { $bits += T 'net.known' }
            if ($st.Pending -and $st.Pending.Ssid -eq $n.Ssid) { $bits = @(T 'net.connecting') }
            $armed = $n.Known -and $st.Armed -eq $n.Ssid
            $sub = $bits -join ' - '
            if ($armed) { $sub = T 'net.forget_confirm' }
            $row = & $newNetRow $n ($n.Ssid -eq $st.Sel) $armed $sub
            [void]$f.Nets.Children.Add($row)
            if ($n.Ssid -eq $st.Sel) { $selRow = $row }
        }
        if ($Reveal -and $selRow) { $selRow.BringIntoView() }
        $note = ''
        if (-not $hasIf) { $note = '' }
        elseif (-not $s.RadioOn) { $note = T 'net.radio_off' }
        elseif (-not $nets.Count) { $note = T 'net.searching' }
        else { $note = T 'net.rescan' }
        $f.NetsNote.Text = $note
        $f.NetsPill.Visibility = if ($nets.Count) { 'Visible' } else { 'Collapsed' }
        $f.NetsCount.Text = [string]$nets.Count
    }

    $renderWifi = {
        $s = $st.State
        $hasIf = $s -and $s.HasInterface
        $radio.IsEnabled = [bool]($hasIf -and -not $s.HardwareOff)
        $st.Updating = $true
        $radio.IsChecked = [bool]($hasIf -and $s.RadioOn)
        $st.Updating = $false

        if ($hasIf -and $s.Connected) {
            $f.ConnDetail.Visibility = 'Visible'
            $f.CurSsid.Text = $s.Ssid
            $f.CurCheck.Content = & $inline (Get-NetIconXaml 'check' 12 $t.success 2.4)
            $f.CurState.Foreground = & $brush $t.successText
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
            $mbps = [Math]::Max($s.RxMbps, $s.TxMbps)
            $sp = (Format-VivacSpeed $mbps) -split ' ', 2
            $f.SpeedNum.Text = $sp[0]; $f.SpeedUnit.Text = $sp[1]
            foreach ($cell in @(@('wifi', (T 'net.signal'), "$($s.Signal) %  ($($s.Rssi) dBm)"), @('sliders', (T 'net.band'), $band),
                    @('bolt', (T 'net.speed'), (Format-VivacSpeed $mbps)), @('target', 'IP', $ip))) {
                [void]$f.CurStats.Children.Add((& $inline (Get-NetStatXaml $t $cell[0] $cell[1] $cell[2])))
            }
            if (-not $st.ForgetArmed) { & $softForget }
        } else {
            $f.ConnDetail.Visibility = 'Collapsed'
            $f.CurSsid.Text = 'Wi-Fi'
            $f.CurCheck.Content = $null
            $f.CurState.Foreground = & $brush $t.textSecondary
            $sub = T 'net.offline'
            if (-not $hasIf) { $sub = T 'net.no_wifi' }
            elseif ($s.HardwareOff) { $sub = T 'net.radio_hard_off' }
            elseif (-not $s.RadioOn) { $sub = T 'net.radio_off' }
            $f.CurState.Text = $sub
        }

        # Two Wi-Fi adapters (the machine's own and a USB stick): which one
        # carries the connection and which waits as the backup.
        $cards = @(Get-VivacWifiAdapters $s)
        $f.WifiCardRows.Children.Clear()
        foreach ($c in $cards) {
            $state = if ($c.Carries) { T 'net.carries' } else { T 'net.backup' }
            if (-not $c.Up) { $state = "$state - $(T 'net.offline')" }
            $color = if ($c.Carries) { $t.accent } else { $t.muted }
            $x = "<Grid Margin=`"0,3`"><Grid.ColumnDefinitions><ColumnDefinition Width=`"Auto`"/><ColumnDefinition Width=`"*`"/></Grid.ColumnDefinitions>$(Get-NetTileXaml $t 'wifi' 30 $t.surfaceAlt $color)" +
                "<StackPanel Grid.Column=`"1`" Margin=`"10,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$(ConvertTo-NetXml $c.Description)`" FontSize=`"12`" FontWeight=`"Bold`" Foreground=`"#$($t.text)`" TextTrimming=`"CharacterEllipsis`"/>" +
                "<TextBlock Text=`"$(ConvertTo-NetXml $state)`" FontSize=`"11`" Foreground=`"#$(if ($c.Carries) { $t.successText } else { $t.textSecondary })`"/></StackPanel></Grid>"
            [void]$f.WifiCardRows.Children.Add((& $inline $x))
        }
        $f.WifiCards.Visibility = if ($cards.Count) { 'Visible' } else { 'Collapsed' }

        & $renderNets
        & $drawSpark
    }

    $renderEth = {
        $f.Adapters.Children.Clear()
        $wired = @()
        if ($st.State) { $wired = @($st.State.Adapters | Where-Object { -not $_.Wifi }) }
        if (-not $wired.Count) {
            $none = & $inline "<TextBlock Text=`"$(ConvertTo-NetXml (T 'net.no_wired'))`" Foreground=`"#$($t.muted)`" Margin=`"4,0,0,12`"/>"
            [void]$f.Adapters.Children.Add($none)
            return
        }
        foreach ($a in $wired) {
            $name = ConvertTo-NetXml $a.Name
            $desc = ConvertTo-NetXml $a.Description
            if ($a.Up) {
                $stateX = "<StackPanel Orientation=`"Horizontal`" Margin=`"0,2,0,0`"><Grid Margin=`"0,0,6,0`" VerticalAlignment=`"Center`">$(Get-NetIconXaml 'check' 12 $t.success 2.4)</Grid><TextBlock Text=`"$(ConvertTo-NetXml "$(T 'net.connected') - $(Format-VivacSpeed $a.SpeedMbps)")`" FontSize=`"12`" Foreground=`"#$($t.successText)`"/></StackPanel>"
                $tileColor = $t.accent
            } else {
                $stateX = "<TextBlock Text=`"$(ConvertTo-NetXml (T 'net.cable_out'))`" FontSize=`"12`" Foreground=`"#$($t.textSecondary)`" Margin=`"0,2,0,0`"/>"
                $tileColor = $t.muted
            }
            $cells = ''
            if ($a.Up) {
                $v4 = ($a.Ipv4 -join ', '); if (-not $v4) { $v4 = '-' }
                $gw = ($a.Gateways -join ', '); if (-not $gw) { $gw = '-' }
                $dns = (@($a.Dns | Select-Object -First 2) -join ', '); if (-not $dns) { $dns = '-' }
                $mode = if ($a.Dhcp) { 'DHCP' } else { T 'net.static' }
                $list = @(@('target', 'IPv4', $v4), @('ethernet', (T 'net.gateway'), $gw), @('search', 'DNS', $dns), @('sliders', (T 'net.mode'), $mode))
                if ($a.Ipv6.Count) { $list += , @('target', 'IPv6', $a.Ipv6[0]) }
                $list += , @('box', 'MAC', $a.Mac)
                $cells = "<UniformGrid Columns=`"2`" Margin=`"-3,10,-3,0`">$(-join ($list | ForEach-Object { Get-NetStatXaml $t $_[0] $_[1] $_[2] }))</UniformGrid>"
            }
            $btns = ''
            if ($a.Up -and $a.Ipv4.Count) { $btns += Get-NetButtonXaml $t 'Copy' (T 'net.copy_ip') '' 'neutral' 32 'Margin="0,0,8,0"' }
            if ($a.Up -and $a.Dhcp) { $btns += Get-NetButtonXaml $t 'Renew' (T 'net.renew') 'restart' 'neutral' 32 }
            if ($btns) { $btns = "<StackPanel Orientation=`"Horizontal`" Margin=`"0,8,0,0`">$btns</StackPanel>" }
            $x = @"
<Border Background="#$($t.surface)" CornerRadius="12" Padding="12" Margin="0,0,0,12">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      $(Get-NetTileXaml $t 'ethernet' 36 $t.surfaceAlt $tileColor)
      <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="$name" FontSize="14" FontWeight="Bold" Foreground="#$($t.text)" TextTrimming="CharacterEllipsis"/>$stateX</StackPanel>
    </Grid>
    <TextBlock Text="$desc" FontSize="11" Foreground="#$($t.muted)" Margin="2,8,0,0" TextTrimming="CharacterEllipsis"/>
    $cells$btns
  </StackPanel>
</Border>
"@
            $card = & $inline $x
            $ipText = if ($a.Ipv4.Count) { $a.Ipv4[0] } else { '' }
            $copy = $card.FindName('Copy')
            if ($copy) { $copy.Tag = $ipText; $copy.Add_Click({ param($s) Set-Clipboard -Value $s.Tag; Set-NetButtonText $s (T 'net.copied') }) }
            $renew = $card.FindName('Renew')
            if ($renew) {
                $renew.Tag = $a.Name
                # Renewing the lease takes an administrator; Windows asks.
                $renew.Add_Click({ param($s) try { Start-Process ipconfig.exe -ArgumentList '/renew', "`"$($s.Tag)`"" -Verb RunAs -WindowStyle Hidden } catch { } })
            }
            [void]$f.Adapters.Children.Add($card)
        }
    }

    $render = {
        if ($st.State) { $f.Subtitle.Text = Get-VivacNetworkSummary $st.State }
        & $renderWifi
        & $renderEth
        & $drawTabs
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
        $f.Ask.BringIntoView()
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
                $t0 = $st.Task; $st.Task = $null
                if (-not $t0.IsFaulted) {
                    $first = -not $st.State
                    $st.State = $t0.Result
                    if ($st.State.Connected) {
                        [void]$st.History.Add([double][Math]::Max($st.State.RxMbps, $st.State.TxMbps))
                        while ($st.History.Count -gt 30) { $st.History.RemoveAt(0) }
                    }
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
                Set-NetButtonText $f.ForgetCur (T 'net.forget_confirm')
                $f.ForgetCur.Background = & $brush $t.alert
                $f.ForgetCur.Foreground = & $brush $t.bg
                return
            }
            $st.ForgetArmed = $false
            & $softForget
            [void][VivacNetwork]::Forget($st.State.Interface, $st.State.Profile)
            $st.Next = $st.Ticks + 3
        })
    $f.WifiSettings.Add_Click({ $window.Close(); Start-Process 'ms-settings:network-wifi' })
    $f.NetSettings.Add_Click({ $window.Close(); Start-Process 'ms-settings:network' })
    $f.Ncpa.Add_Click({ $window.Close(); Start-Process 'ncpa.cpl' })
    $f.AskGo.Add_Click({ & $connectWithKey })
    $f.AskCancel.Add_Click({ & $hideAsk })
    $f.Scan.Add_Click({ & $scan })
    $f.TabWifi.Add_MouseLeftButtonUp({ & $setTab 'wifi' })
    $f.TabEth.Add_MouseLeftButtonUp({ & $setTab 'ethernet' })
    $f.SparkBox.Add_SizeChanged({ & $drawSpark })

    # The row under a click, found from what was hit.
    $rowAt = {
        param($Source)
        $d = $Source
        while ($d) {
            if ($d -is [Windows.Controls.Border] -and $d.Tag -is [hashtable] -and $d.Tag.ContainsKey('Net')) { return $d }
            if ($d -is [Windows.Media.Visual] -or $d -is [Windows.Media.Media3D.Visual3D]) { $d = [Windows.Media.VisualTreeHelper]::GetParent($d) }
            else { $d = $d.Parent }
        }
        $null
    }

    # A click on a network joins it; a right click on a known one forgets it,
    # after a second right click.
    $f.Nets.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $row = & $rowAt $e.OriginalSource
            if (-not $row) { return }
            $st.Armed = ''
            $st.Sel = $row.Tag.Net.Ssid
            & $connect $row.Tag.Net
            & $renderNets
        })
    $f.Nets.Add_PreviewMouseRightButtonUp({
            param($s, $e)
            $row = & $rowAt $e.OriginalSource
            if (-not $row) { return }
            $n = $row.Tag.Net
            if (-not $n.Known) { return }
            if ($st.Armed -eq $n.Ssid) {
                $st.Armed = ''
                [void][VivacNetwork]::Forget($st.State.Interface, $n.Profile)
                $st.Next = $st.Ticks + 2
            } else {
                $st.Armed = $n.Ssid
            }
            & $renderNets
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
            $list = @($st.NetList)
            $i = -1
            for ($j = 0; $j -lt $list.Count; $j++) { if ($list[$j].Ssid -eq $st.Sel) { $i = $j } }
            if ($k -eq 'Down' -and $list.Count) { $st.Sel = $list[[Math]::Min($list.Count - 1, $i + 1)].Ssid; $st.Armed = ''; & $renderNets $true; $e.Handled = $true; return }
            if ($k -eq 'Up' -and $list.Count) { $st.Sel = $list[[Math]::Max(0, $i - 1)].Ssid; $st.Armed = ''; & $renderNets $true; $e.Handled = $true; return }
            if ($k -eq 'Return' -and $i -ge 0) { & $connect $list[$i]; & $renderNets; $e.Handled = $true; return }
        })

    # The host turns an open panel to the other tab when the pointer rests on the other pill.
    $window.Resources['vivac.setTab'] = $setTab
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
    Format-VivacSpeed, New-VivacWifiProfileXml, Get-VivacNetworkSummary, Set-VivacWifiRadio, Get-VivacWifiAdapters, Get-VivacSparkPoints
