# The drawn half of the WPF kit: the pieces the redesigned panels share with
# the Linux side (linux/lib/vivacpanel/draw.py is the geometry's reference).
#
#   Get-KitTokens $p                    the palette as the design canvas names it
#   Get-KitWindowXamlV2 / Get-KitPanelXamlV2
#                                       window and panel in the redesigned chrome:
#                                       radius 14, a 36 px tile header, key caps
#   Add-KitDrawResources $window $p     the styles below, into the window's
#                                       resources (so Get-KitResourcesXaml stays
#                                       as it is): KitFader, KitChip, KitChipSel,
#                                       KitChipOn, KitMute, KitMuteOn, KitAction,
#                                       KitActionPrimary, KitActionDanger, KitOutline
#   New-KitChip, New-KitFader, New-KitRuler, New-KitNotchBar / Set-KitNotchBar,
#   New-KitRing / Set-KitRing, New-KitGlyph, New-KitText
#
# Nothing here reads settings or strings: a caller passes the palette and the
# texts, so a test builds any of it without a theme.

Set-StrictMode -Version 2.0

$script:KitIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$script:KitFont = 'JetBrainsMono Nerd Font, Cascadia Mono, Consolas'

# The palette under the names the design canvas and the Linux panels use. A
# token a theme lacks falls back to something that reads on its background.
function Get-KitTokens($p) {
    $pick = { param($key, $fallback) if ($p.Contains($key) -and $p[$key]) { [string]$p[$key] } else { $fallback } }
    $t = [ordered]@{
        bg            = & $pick 'COLOR_BG' '1E1E2E'
        surface       = & $pick 'COLOR_SURFACE' '2A2A3A'
        surfaceAlt    = & $pick 'COLOR_SURFACE_ALT' '3A3A4A'
        accent        = & $pick 'COLOR_ACCENT' 'C0A060'
        text          = & $pick 'COLOR_FG' 'E0E0E0'
        textSecondary = & $pick 'COLOR_FG_DIM' 'B0B0B0'
        line          = & $pick 'COLOR_BORDER_INACTIVE' '444444'
        alert         = & $pick 'COLOR_URGENT' 'C05050'
        info          = & $pick 'COLOR_INFO' '5090C0'
        success       = & $pick 'COLOR_OK' '50A080'
        muted         = & $pick 'COLOR_MUTED' '888888'
    }
    $t['actionFill'] = $t['accent']
    $t['actionText'] = $t['bg']
    # The accent a quarter of the way to white, as kit.py's mix() does.
    $ring = foreach ($at in 0, 2, 4) {
        $c = [Convert]::ToInt32($t['accent'].Substring($at, 2), 16)
        [int][Math]::Round($c + (255 - $c) * 0.25)
    }
    $t['focusRing'] = '{0:X2}{1:X2}{2:X2}' -f $ring[0], $ring[1], $ring[2]
    $t
}

# --------------------------------------------------------------- the chrome

function Get-KitHintsXamlV2($t, [object[]]$Pairs) {
    $out = foreach ($pair in $Pairs) {
        $key = [Security.SecurityElement]::Escape([string]$pair[0])
        $label = [Security.SecurityElement]::Escape([string]$pair[1])
        "<StackPanel Orientation=`"Horizontal`" Margin=`"0,0,14,0`"><Border Background=`"#$($t['surface'])`" BorderBrush=`"#$($t['line'])`" BorderThickness=`"0,0,0,2`" CornerRadius=`"6`" Padding=`"6,1`" Margin=`"0,0,6,0`"><TextBlock Text=`"$key`" FontSize=`"11`" Foreground=`"#$($t['text'])`"/></Border><TextBlock Text=`"$label`" FontSize=`"11`" Foreground=`"#$($t['textSecondary'])`" VerticalAlignment=`"Center`"/></StackPanel>"
    }
    "<WrapPanel>$(-join $out)</WrapPanel>"
}

# A panel's window: transparent, borderless, the panel's own frame inside.
function Get-KitWindowXamlV2($t, [string]$Title, [int]$Width, [string]$Body) {
    $safe = [Security.SecurityElement]::Escape($Title)
    @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$safe" Width="$Width" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True" ShowInTaskbar="False"
        FontFamily="$script:KitFont" FontSize="13" Foreground="#$($t['text'])" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Border Background="#F2$($t['bg'])" BorderBrush="#$($t['accent'])" BorderThickness="2" CornerRadius="14" Padding="14,14,14,10">
$Body
  </Border>
</Window>
"@
}

# Header (tile, title, a line named Subtitle, a slot named HeaderRight), the
# body, and the key caps at the foot under a line. The panel's pieces are
# named so a caller reaches them: Subtitle, HeaderRight, Foot.
function Get-KitPanelXamlV2($t, [string]$Glyph, [string]$Title, [string]$Body, [object[]]$Hints = @()) {
    $foot = ''
    if ($Hints.Count) {
        $foot = "<Border x:Name=`"Foot`" DockPanel.Dock=`"Bottom`" Margin=`"0,12,0,0`" Padding=`"2,8,0,0`" BorderBrush=`"#$($t['line'])`" BorderThickness=`"0,1,0,0`">$(Get-KitHintsXamlV2 $t $Hints)</Border>"
    }
    $safe = [Security.SecurityElement]::Escape($Title)
    @"
<Grid>
  <DockPanel>
    <Grid DockPanel.Dock="Top" Margin="2,0,2,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Width="36" Height="36" CornerRadius="10" Background="#$($t['surface'])">
        <TextBlock x:Name="HeadGlyph" Text="$Glyph" FontFamily="$script:KitIconFont" FontSize="18" Foreground="#$($t['accent'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
        <TextBlock Text="$safe" FontSize="15" FontWeight="Bold" Foreground="#$($t['text'])"/>
        <TextBlock x:Name="Subtitle" FontSize="12" Foreground="#$($t['textSecondary'])" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <StackPanel x:Name="HeaderRight" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"/>
    </Grid>
    $foot
    $Body
  </DockPanel>
</Grid>
"@
}

# ------------------------------------------------------------------ styles

# $FaderMax is the top of the fader: 100 where the system's scalar ends there
# (Windows), 150 on Linux, where the part past 100 is tinted alert.
function Get-KitDrawResourcesXaml($t, [int]$FaderMax = 100) {
    $zone = ''
    if ($FaderMax -gt 100) {
        $zone = "<Grid Margin=`"10,0`"><Grid.ColumnDefinitions><ColumnDefinition Width=`"100*`"/><ColumnDefinition Width=`"$($FaderMax - 100)*`"/></Grid.ColumnDefinitions><Border Grid.Column=`"1`" Background=`"#47$($t['alert'])`"/><Border Grid.Column=`"1`" Width=`"2`" Height=`"16`" HorizontalAlignment=`"Left`" Margin=`"-1,0,0,0`" Background=`"#B3$($t['textSecondary'])`"/></Grid>"
    }
    @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
<Style TargetType="ScrollBar">
  <Setter Property="Width" Value="6"/>
  <Setter Property="MinWidth" Value="6"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
    <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#$($t['surfaceAlt'])"/>
      </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
    </Track>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitFader" TargetType="Slider">
  <Setter Property="IsMoveToPointEnabled" Value="True"/>
  <Setter Property="Minimum" Value="0"/>
  <Setter Property="Maximum" Value="$FaderMax"/>
  <Setter Property="Foreground" Value="#$($t['accent'])"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
    <Grid Background="Transparent" Height="26">
      <Grid Height="10" VerticalAlignment="Center">
        <Border CornerRadius="5" Background="#$($t['surfaceAlt'])"/>
        <Border CornerRadius="5" ClipToBounds="True">$zone</Border>
      </Grid>
      <Track x:Name="PART_Track">
        <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
          <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="10" CornerRadius="5,0,0,5" Background="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template>
        </RepeatButton></Track.DecreaseRepeatButton>
        <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
          <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template>
        </RepeatButton></Track.IncreaseRepeatButton>
        <Track.Thumb><Thumb Focusable="False"><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Grid Width="20" Height="20"><Ellipse Fill="#$($t['bg'])"/><Ellipse Width="16" Height="16" Fill="#$($t['text'])"/></Grid>
        </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
      </Track>
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitChip" TargetType="Button">
  <Setter Property="Foreground" Value="#$($t['text'])"/>
  <Setter Property="Background" Value="#$($t['surfaceAlt'])"/>
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="10,0" MinHeight="28">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t['line'])"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitChipSel" TargetType="Button" BasedOn="{StaticResource KitChip}">
  <Setter Property="Foreground" Value="#$($t['actionText'])"/>
  <Setter Property="FontWeight" Value="Bold"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Grid Margin="-4">
      <Border BorderBrush="#$($t['focusRing'])" BorderThickness="2" CornerRadius="12"/>
      <Border Margin="2" BorderBrush="#$($t['bg'])" BorderThickness="2" CornerRadius="10"/>
      <Border Margin="4" Background="#$($t['actionFill'])" CornerRadius="8" Padding="10,0" MinHeight="28">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitChipOn" TargetType="Button" BasedOn="{StaticResource KitChip}">
  <Setter Property="Foreground" Value="#$($t['actionText'])"/>
  <Setter Property="FontWeight" Value="Bold"/>
  <Setter Property="Background" Value="#$($t['actionFill'])"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border Background="#$($t['actionFill'])" CornerRadius="8" Padding="10,0" MinHeight="28">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitMute" TargetType="Button">
  <Setter Property="Foreground" Value="#$($t['accent'])"/>
  <Setter Property="Background" Value="#$($t['surfaceAlt'])"/>
  <Setter Property="FontFamily" Value="$script:KitIconFont"/>
  <Setter Property="FontSize" Value="16"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Width" Value="32"/>
  <Setter Property="Height" Value="32"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitMuteOn" TargetType="Button" BasedOn="{StaticResource KitMute}">
  <Setter Property="Background" Value="#$($t['alert'])"/>
  <Setter Property="Foreground" Value="#$($t['bg'])"/>
</Style>
<Style x:Key="KitAction" TargetType="Button">
  <Setter Property="Foreground" Value="#$($t['text'])"/>
  <Setter Property="Background" Value="#$($t['surfaceAlt'])"/>
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="12,6" MinHeight="32">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t['actionFill'])"/><Setter Property="Foreground" Value="#$($t['actionText'])"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitActionPrimary" TargetType="Button" BasedOn="{StaticResource KitAction}">
  <Setter Property="Background" Value="#$($t['actionFill'])"/>
  <Setter Property="Foreground" Value="#$($t['actionText'])"/>
  <Setter Property="FontWeight" Value="Bold"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="12,6" MinHeight="32">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t['focusRing'])"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitActionDanger" TargetType="Button" BasedOn="{StaticResource KitAction}">
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="12,6" MinHeight="32">
      <ContentPresenter x:Name="Cp" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t['alert'])"/><Setter Property="Foreground" Value="#$($t['bg'])"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitOutline" TargetType="Button">
  <Setter Property="Foreground" Value="#$($t['alert'])"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#$($t['alert'])" BorderThickness="1" CornerRadius="8" Padding="10,0" MinHeight="28">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t['alert'])"/><Setter Property="Foreground" Value="#$($t['bg'])"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
</ResourceDictionary>
"@
}

# The styles into a window's own resources, so a window built from any chrome
# can use them: $control.Style = $window.FindResource('KitFader').
function Add-KitDrawResources($Window, $p, [int]$FaderMax = 100) {
    $t = Get-KitTokens $p
    $dict = [Windows.Markup.XamlReader]::Parse((Get-KitDrawResourcesXaml $t $FaderMax))
    $Window.Resources.MergedDictionaries.Add($dict)
}

# ----------------------------------------------------------------- the pieces

function New-KitBrush([string]$Hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString("#$Hex"))
    $b.Freeze()
    $b
}

# A text, in the kit's size and colour.
function New-KitText([string]$Text, [string]$Color, [double]$Size = 13, [switch]$Bold) {
    $x = New-Object Windows.Controls.TextBlock
    $x.Text = $Text; $x.Foreground = New-KitBrush $Color; $x.FontSize = $Size
    $x.VerticalAlignment = 'Center'
    if ($Bold) { $x.FontWeight = 'Bold' }
    $x
}

# An icon-font glyph.
function New-KitGlyph([int]$Code, [string]$Color, [double]$Size = 16) {
    $x = New-KitText ([string][char]$Code) $Color $Size
    $x.FontFamily = New-Object Windows.Media.FontFamily $script:KitIconFont
    $x
}

# A chip: its text and, after it, a count or a value in the second colour.
# $Window gives the styles (Add-KitDrawResources); $Selected takes the filled
# look with a ring (-NoRing: without it, as the clipboard's filters). Returns the Button; its Tag keeps the parts.
function New-KitChip($Window, $t, [string]$Text, [string]$Count = '', [switch]$Selected, [string]$Check = '', [switch]$NoRing) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $Window.FindResource($(if ($Selected -and $NoRing) { 'KitChipOn' } elseif ($Selected) { 'KitChipSel' } else { 'KitChip' }))
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    if ($Check) {
        $c = New-KitText $Check $(if ($Selected) { $t['actionText'] } else { $t['text'] }) 12
        $c.Margin = '0,0,6,0'
        [void]$row.Children.Add($c)
    }
    $label = New-KitText $Text $(if ($Selected) { $t['actionText'] } else { $t['text'] }) 12
    $label.TextTrimming = 'CharacterEllipsis'
    if ($Selected) { $label.FontWeight = 'Bold' }
    [void]$row.Children.Add($label)
    $n = $null
    if ($Count -ne '') {
        $n = New-KitText $Count $(if ($Selected) { $t['actionText'] } else { $t['textSecondary'] }) 12
        $n.Margin = '6,0,0,0'
        [void]$row.Children.Add($n)
    }
    $b.Content = $row
    $b.Tag = @{ Label = $label; Count = $n }
    $b
}

# A level control 0..$Max: the fill up to the value (accent, or muted), the
# end of the track tinted when $Max passes 100, a round knob. Returns the
# Slider; raise ValueChanged as for any Slider.
function New-KitFader($Window, $t, [int]$Value, [int]$Max = 100, [bool]$Muted = $false) {
    $s = New-Object Windows.Controls.Slider
    $s.Style = $Window.FindResource('KitFader')
    $s.Minimum = 0
    $s.Maximum = $Max
    $s.Value = [Math]::Max(0, [Math]::Min($Max, $Value))
    $s.Foreground = New-KitBrush $(if ($Muted) { $t['muted'] } else { $t['accent'] })
    $s.HorizontalAlignment = 'Stretch'
    $s
}

# 0 / 25 / 50 / 75 / 100 under a fader, each at the place its knob takes.
function New-KitRuler($t, [int[]]$Values) {
    $g = New-Object Windows.Controls.Grid
    $g.Height = 16
    $g.Margin = '0,0,0,0'
    foreach ($v in $Values) {
        $x = New-KitText "$v" $t['textSecondary'] 10
        $x.VerticalAlignment = 'Top'
        $x.Tag = $v
        [void]$g.Children.Add($x)
    }
    # A label sits at (10 + (width - 20) * v / max) centred; the first and last
    # lean to the edges as the Linux ruler's do. Placed again at every size.
    $max = [double]($Values | Measure-Object -Maximum).Maximum
    $g.Add_SizeChanged({
            param($s)
            $w = $s.ActualWidth
            foreach ($c in $s.Children) {
                $c.Measure([Windows.Size]::new([double]::PositiveInfinity, 16))
                $tw = $c.DesiredSize.Width
                $v = [double]$c.Tag
                $x = 10 + ($w - 20) * $v / $s.Tag
                if ($v -eq 0) { $x = 0 } elseif ($v -eq $s.Tag) { $x = $w - $tw } else { $x = $x - $tw / 2 }
                $c.HorizontalAlignment = 'Left'
                $c.Margin = [Windows.Thickness]::new($x, 0, 0, 0)
            }
        })
    $g.Tag = $max
    $g
}

# A bar of notches (a vumeter or a capped level): the first part lit in
# accent, past $Danger (0..1) in alert, the rest in the track colour.
function New-KitNotchBar($t, [int]$Ticks = 28, [double]$Height = 8) {
    $u = New-Object Windows.Controls.Primitives.UniformGrid
    $u.Columns = $Ticks; $u.Rows = 1; $u.Height = $Height
    $u.Margin = '-1,0'
    $cells = @()
    for ($i = 0; $i -lt $Ticks; $i++) {
        $b = New-Object Windows.Controls.Border
        $b.Margin = '1,0'
        $b.Background = New-KitBrush $t['surfaceAlt']
        [void]$u.Children.Add($b)
        $cells += $b
    }
    $u.Tag = @{ Cells = $cells; Tokens = $t }
    $u
}

# $Fraction 0..1; $Danger 0..1 or -1 for none.
function Set-KitNotchBar($Bar, [double]$Fraction, [bool]$Muted = $false, [double]$Danger = -1) {
    $t = $Bar.Tag.Tokens
    $cells = $Bar.Tag.Cells
    $n = $cells.Count
    $lit = [int][Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $Fraction)) * $n, [MidpointRounding]::AwayFromZero)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -lt $lit -and -not $Muted) {
            $over = $Danger -ge 0 -and ($i + 1) / $n -gt $Danger
            $cells[$i].Background = New-KitBrush $(if ($over) { $t['alert'] } else { $t['accent'] })
        } else {
            $cells[$i].Background = New-KitBrush $t['surfaceAlt']
        }
    }
    if ($Muted) { 0 } else { $lit }
}

# A ring gauge: track and an arc for the fraction, from 12 o'clock clockwise.
function New-KitRing($t, [double]$Size = 96, [double]$Thickness = 10) {
    $g = New-Object Windows.Controls.Grid
    $g.Width = $Size; $g.Height = $Size
    $r = ($Size - $Thickness) / 2
    $track = New-Object Windows.Shapes.Ellipse
    $track.Width = $Size - $Thickness; $track.Height = $Size - $Thickness
    $track.Stroke = New-KitBrush $t['surfaceAlt']; $track.StrokeThickness = $Thickness
    [void]$g.Children.Add($track)
    $fig = New-Object Windows.Media.PathFigure
    $arc = New-Object Windows.Media.ArcSegment
    $arc.Size = [Windows.Size]::new($r, $r)
    $arc.SweepDirection = 'Clockwise'
    $fig.Segments.Add($arc)
    $geo = New-Object Windows.Media.PathGeometry
    $geo.Figures.Add($fig)
    $path = New-Object Windows.Shapes.Path
    $path.Data = $geo
    $path.Stroke = New-KitBrush $t['accent']; $path.StrokeThickness = $Thickness
    $path.StrokeStartLineCap = 'Round'; $path.StrokeEndLineCap = 'Round'
    [void]$g.Children.Add($path)
    $g.Tag = @{ Path = $path; Figure = $fig; Arc = $arc; Radius = $r; Center = $Size / 2; Tokens = $t; Size = $Size; Thickness = $Thickness }
    $g
}

function Set-KitRing($Ring, [double]$Fraction, [string]$Kind = '') {
    $s = $Ring.Tag
    $f = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))
    $s.Path.Stroke = New-KitBrush $(if ($Kind -eq 'alert') { $s.Tokens['alert'] } else { $s.Tokens['accent'] })
    if ($f -le 0) { $s.Path.Visibility = 'Collapsed'; return }
    $s.Path.Visibility = 'Visible'
    $c = $s.Center; $r = $s.Radius
    # A whole turn would start and end on one point and draw nothing.
    $f = [Math]::Min($f, 0.9999)
    $angle = -[Math]::PI / 2 + 2 * [Math]::PI * $f
    $s.Figure.StartPoint = [Windows.Point]::new($c, $c - $r)
    $s.Arc.Point = [Windows.Point]::new($c + $r * [Math]::Cos($angle), $c + $r * [Math]::Sin($angle))
    $s.Arc.IsLargeArc = $f -gt 0.5
}
