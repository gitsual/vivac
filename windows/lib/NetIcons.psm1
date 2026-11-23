# The stroke icons the network and Bluetooth panels draw that PanelKit's set
# lacks (wifi, ethernet, bluetooth, headphones, keyboard, gamepad, speaker,
# trash, plug, sliders, and a few more), in the same 24 x 24 grid and 2 px
# round stroke as the design's.
#
# PanelKit keeps its icons in a table of its own, which this module adds to
# (the module is not edited): after Initialize-NetIcons, Get-PanelIconXaml
# knows every name below. The helpers here call it first, so an icon is there
# even when PanelKit was reloaded after this module.
#
#   Initialize-NetIcons                 add the icons to PanelKit's table
#   Get-NetIconXaml  $name $size $color a stroke icon (a Viewbox)
#   Get-NetTileXaml  $t $icon $size     the rounded tile with an icon in it
#   Get-NetBarsXaml  $t $signal $color  four signal bars, lit up to the signal
#   Get-NetButtonXaml / Set-NetButtonText   a PanelKit button with a label that can change
#   Get-NetSwitchXaml $t $name          an on/off switch
#   Get-NetStatXaml $t $icon $label $value   a datum cell of the connection grid
#
# Everything returns XAML text, parsed once by the caller.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

$script:NetIcons = @{
    wifi       = '<path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.8 16a5 5 0 0 1 6.4 0M12 19.5v.01"/>'
    ethernet   = '<rect x="3" y="4" width="18" height="12" rx="2.5"/><path d="M8 20h8M12 16v4"/>'
    bluetooth  = '<path d="M7 7.5l10 9-5 4.5V3l5 4.5-10 9"/>'
    headphones = '<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/>'
    keyboard   = '<rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h.01M10 10h.01M14 10h.01M17.5 10h.01M7.5 14h9"/>'
    gamepad    = '<path d="M6.5 8h11a4.5 4.5 0 0 1 4.5 4.5v1a3 3 0 0 1-5.3 1.9L15.5 14h-7l-1.2 1.4A3 3 0 0 1 2 13.5v-1A4.5 4.5 0 0 1 6.5 8z"/><path d="M8 10.5v3M6.5 12h3M16 11h.01M18 13h.01"/>'
    speaker    = '<path d="M11 5L6.5 9H3v6h3.5L11 19z"/><path d="M15 9.5a4 4 0 0 1 0 5M18 7a8 8 0 0 1 0 10"/>'
    trash      = '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>'
    plug       = '<path d="M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/>'
    sliders    = '<path d="M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4"/>'
    bolt       = '<path d="M13 3L5 13.5h6L10 21l8-10.5h-6z"/>'
    target     = '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/>'
    unlock     = '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.6-1.7"/>'
    mouse      = '<rect x="6" y="3" width="12" height="18" rx="6"/><path d="M12 7v3"/>'
    device     = '<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/>'
}

function Initialize-NetIcons {
    $pk = Get-Module PanelKit
    if (-not $pk) { $pk = Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1') -PassThru }
    & $pk {
        param($add)
        foreach ($k in $add.Keys) { if (-not $script:PanelIcons.ContainsKey($k)) { $script:PanelIcons[$k] = $add[$k] } }
    } $script:NetIcons
}

function Get-NetIconXaml([string]$Name, [double]$Size, [string]$Color, [double]$Stroke = 2, [string]$Extra = '') {
    Initialize-NetIcons
    Get-PanelIconXaml $Name $Size $Color $Stroke $Extra
}

# A tile: a rounded square in a fill (the surface-alt colour unless given),
# the icon centred in it.
function Get-NetTileXaml($t, [string]$Icon, [int]$Size = 36, [string]$Fill = '', [string]$Color = '', [string]$Extra = '') {
    if (-not $Fill) { $Fill = $t.surfaceAlt }
    if (-not $Color) { $Color = $t.accent }
    $glyph = [Math]::Round($Size * 0.5)
    "<Border Width=`"$Size`" Height=`"$Size`" CornerRadius=`"10`" Background=`"#$Fill`" VerticalAlignment=`"Center`" $Extra><Grid HorizontalAlignment=`"Center`" VerticalAlignment=`"Center`">$(Get-NetIconXaml $Icon $glyph $Color)</Grid></Border>"
}

# How many of the four bars a signal (0 to 100) lights.
function Get-NetBarCount([int]$Signal) {
    if ($Signal -ge 75) { return 4 }
    if ($Signal -ge 50) { return 3 }
    if ($Signal -ge 25) { return 2 }
    if ($Signal -gt 0) { return 1 }
    0
}

# Four bars of rising height; the lit ones in $Color, the rest in $Dim.
function Get-NetBarsXaml($t, [int]$Signal, [string]$Color, [string]$Dim = '') {
    if (-not $Dim) { $Dim = ConvertTo-PanelMix $t.surfaceAlt $Color 0.25 }
    $lit = Get-NetBarCount $Signal
    $bars = for ($i = 1; $i -le 4; $i++) {
        $fill = $Dim
        if ($i -le $lit) { $fill = $Color }
        $h = 3 + 3 * $i
        "<Border Width=`"3`" Height=`"$h`" Margin=`"0,0,2,0`" CornerRadius=`"1`" VerticalAlignment=`"Bottom`" Background=`"#$fill`"/>"
    }
    "<StackPanel Orientation=`"Horizontal`" VerticalAlignment=`"Center`" Height=`"15`">$(-join $bars)</StackPanel>"
}

# A PanelKit button whose label can be changed afterwards (Set-NetButtonText):
# PanelKit writes the label into the template, so it is given a name here.
function Get-NetButtonXaml($t, [string]$Name, [string]$Text, [string]$Icon = '', [string]$Kind = 'neutral', [int]$Height = 34, [string]$Extra = '') {
    Initialize-NetIcons
    $x = Get-PanelButtonXaml $t $Name $Text $Icon $Kind $Height $Extra
    $x -replace '<TextBlock Text=', '<TextBlock x:Name="BtnLabel" Text='
}

function Set-NetButtonText($Button, [string]$Text) {
    [void]$Button.ApplyTemplate()
    $label = $Button.Template.FindName('BtnLabel', $Button)
    if ($label) { $label.Text = $Text }
}

# An on/off switch, 40 x 22, in the design's colours; IsChecked is the state.
function Get-NetSwitchXaml($t, [string]$Name, [string]$Extra = '') {
    @"
<ToggleButton x:Name="$Name" Cursor="Hand" Focusable="False" VerticalAlignment="Center" $Extra>
  <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
    <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#$($t.surfaceAlt)">
      <Ellipse x:Name="Knob" Width="14" Height="14" Margin="4,0" HorizontalAlignment="Left" Fill="#$($t.muted)"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsChecked" Value="True">
        <Setter TargetName="Track" Property="Background" Value="#$($t.accent)"/>
        <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
        <Setter TargetName="Knob" Property="Fill" Value="#$($t.bg)"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Track" Property="Opacity" Value="0.4"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></ToggleButton.Template>
</ToggleButton>
"@
}

# A datum of a connection: a small icon, a label and a value, in a cell of the
# card's darker tone (the design's 2 x 2 grid).
function Get-NetStatXaml($t, [string]$Icon, [string]$Label, [string]$Value) {
    $cell = ConvertTo-PanelMix $t.surface $t.bg 0.45
    $x = [Security.SecurityElement]::Escape($Value)
    $l = [Security.SecurityElement]::Escape($Label)
    "<Border Background=`"#$cell`" CornerRadius=`"10`" Padding=`"10,8`" Margin=`"3`"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width=`"Auto`"/><ColumnDefinition Width=`"*`"/></Grid.ColumnDefinitions>" +
        "<Grid VerticalAlignment=`"Center`" Margin=`"0,0,8,0`">$(Get-NetIconXaml $Icon 14 $t.muted)</Grid>" +
        "<StackPanel Grid.Column=`"1`"><TextBlock Text=`"$l`" FontSize=`"10`" Foreground=`"#$($t.muted)`" TextTrimming=`"CharacterEllipsis`"/>" +
        "<TextBlock Text=`"$x`" FontSize=`"13`" FontWeight=`"Bold`" Foreground=`"#$($t.text)`" TextTrimming=`"CharacterEllipsis`" ToolTip=`"$x`"/></StackPanel></Grid></Border>"
}

Export-ModuleMember -Function Initialize-NetIcons, Get-NetIconXaml, Get-NetTileXaml, Get-NetBarCount, Get-NetBarsXaml,
    Get-NetButtonXaml, Set-NetButtonText, Get-NetSwitchXaml, Get-NetStatXaml
