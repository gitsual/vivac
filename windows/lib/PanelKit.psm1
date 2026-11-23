# The pieces the redesigned panels (security, updates, menu) are drawn with,
# so they read as the same screens the Arch side draws in GTK: the same
# tokens (the palette's, plus the few soft and text tones derived from it),
# the same radii (14 window, 12 card, 10 button and tile, 8 key and row),
# the same stroke icons, chips, buttons with a focus ring, and key caps.
#
# Everything here returns XAML text, so a panel is one string parsed once
# (or one fragment parsed per row when its content changes). Buttons carry
# their template inline for that reason: a fragment parsed on its own cannot
# see its window's resources.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')

$script:PanelNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

function ConvertTo-PanelXml([string]$s) { [Security.SecurityElement]::Escape($s) }

# a moved T of the way to b; both are six hex digits.
function ConvertTo-PanelMix([string]$A, [string]$B, [double]$T) {
    $out = for ($i = 0; $i -lt 6; $i += 2) {
        $x = [Convert]::ToInt32($A.Substring($i, 2), 16)
        $y = [Convert]::ToInt32($B.Substring($i, 2), 16)
        '{0:X2}' -f [int][Math]::Round($x + ($y - $x) * $T, [MidpointRounding]::AwayFromZero)
    }
    -join $out
}

# The kit's tokens (KitDraw's Get-KitTokens: the palette under the design
# canvas's names), and the tones derived from them exactly as the GTK kit
# derives them (linux/lib/vivacpanel/kit.py, security.py).
function Get-PanelTokens($p) {
    $t = @{}
    $kit = Get-KitTokens $p
    foreach ($k in $kit.Keys) { $t[$k] = $kit[$k] }
    $t.neutralFill = $t.surfaceAlt
    $t.neutralHover = ConvertTo-PanelMix $t.surfaceAlt $t.text 0.11
    $t.alertText = ConvertTo-PanelMix $t.alert $t.text 0.43
    $t.alertSoft = ConvertTo-PanelMix $t.bg $t.alert 0.18
    $t.successText = ConvertTo-PanelMix $t.success $t.text 0.2
    $t.successSoft = ConvertTo-PanelMix $t.bg $t.success 0.18
    $t.infoSoft = ConvertTo-PanelMix $t.bg $t.info 0.18
    $t
}

# ----------------------------------------------------------------- icons

# The design's stroke icons: 24 x 24, drawn with a 2 px round stroke. rect
# and circle elements are turned into paths when an icon is made, and arc
# flags are written apart, which is what WPF's path syntax needs.
$script:PanelIcons = @{
    shield   = '<path d="M12 3l8 3v6c0 4.5-3.2 7.8-8 9-4.8-1.2-8-4.5-8-9V6z"/>'
    shieldbang = '<path d="M12 3l8 3v6c0 4.5-3.2 7.8-8 9-4.8-1.2-8-4.5-8-9V6z"/><path d="M12 8.5v4.5M12 16v.01"/>'
    shieldok = '<path d="M12 3l8 3v6c0 4.5-3.2 7.8-8 9-4.8-1.2-8-4.5-8-9V6z"/><path d="M8.5 12l2.5 2.5L15.5 9.5"/>'
    warn     = '<path d="M12 4l9 16H3z"/><path d="M12 10v4.5M12 17.3v.01"/>'
    cross    = '<circle cx="12" cy="12" r="9"/><path d="M8.5 8.5l7 7M15.5 8.5l-7 7"/>'
    check    = '<path d="M5 12.5l4.5 4.5L19 7.5"/>'
    flame    = '<path d="M12 3c1 3.5 5 5.5 5 10a5 5 0 0 1-10 0c0-2 1-3.2 2-4.5.3 1.5 1 2 1.8 2.2C10.5 8 11 5.5 12 3z"/>'
    search   = '<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>'
    calendar = '<rect x="4" y="5" width="16" height="15" rx="2.5"/><path d="M4 10h16M8 3v4M16 3v4"/>'
    lock     = '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>'
    play     = '<path d="M8 5l11 7-11 7z"/>'
    refresh  = '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/>'
    restart  = '<path d="M4 12a8 8 0 1 0 2.5-5.8M4 4v5h5"/>'
    download = '<path d="M12 4v11M7.5 11L12 15.5 16.5 11M5 20h14"/>'
    box      = '<path d="M12 3l8 4v10l-8 4-8-4V7zM4 7l8 4 8-4M12 11v10"/>'
    history  = '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6M3.5 4v4.5H8M12 8v4.5l3 2"/>'
    external = '<path d="M14 4h6v6M20 4l-9 9M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>'
    terminal = '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7 10l3 2.5L7 15M12.5 15H17"/>'
}

function ConvertTo-PanelPathData([string]$Element, [string]$Attrs) {
    $a = @{}
    foreach ($m in [regex]::Matches($Attrs, '(\w+)="([^"]*)"')) { $a[$m.Groups[1].Value] = $m.Groups[2].Value }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $f = { param($k, $d) if ($a.ContainsKey($k)) { [double]::Parse($a[$k], $inv) } else { $d } }
    switch ($Element) {
        'path' { return $a['d'] }
        'circle' {
            $cx = & $f 'cx' 0; $cy = & $f 'cy' 0; $r = & $f 'r' 0
            return ('M{0},{1} A{2},{2} 0 1 1 {3},{1} A{2},{2} 0 1 1 {0},{1} Z' -f ($cx - $r).ToString($inv), $cy.ToString($inv), $r.ToString($inv), ($cx + $r).ToString($inv))
        }
        'rect' {
            $x = & $f 'x' 0; $y = & $f 'y' 0; $w = & $f 'width' 0; $h = & $f 'height' 0; $r = & $f 'rx' 0
            $n = { param([double]$d) $d.ToString($inv) }
            $xr = & $n ($x + $r); $x1r = & $n ($x + $w - $r); $yr = & $n ($y + $r); $y1r = & $n ($y + $h - $r)
            $x0 = & $n $x; $y0 = & $n $y; $x1 = & $n ($x + $w); $y1 = & $n ($y + $h); $rr = & $n $r
            return "M$xr,$y0 H$x1r A$rr,$rr 0 0 1 $x1,$yr V$y1r A$rr,$rr 0 0 1 $x1r,$y1 H$xr A$rr,$rr 0 0 1 $x0,$y1r V$yr A$rr,$rr 0 0 1 $xr,$y0 Z"
        }
    }
    ''
}

# An icon as a Viewbox of the given size, stroked in Color (six hex digits).
function Get-PanelIconXaml([string]$Name, [double]$Size, [string]$Color, [double]$Stroke = 2, [string]$Extra = '') {
    $svg = $script:PanelIcons[$Name]
    if (-not $svg) { throw "no panel icon '$Name'" }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $paths = foreach ($m in [regex]::Matches($svg, '<(path|rect|circle)\s+([^>]*?)/>')) {
        $d = ConvertTo-PanelPathData $m.Groups[1].Value $m.Groups[2].Value
        $filled = $m.Groups[2].Value -match 'fill="currentColor"'
        if ($filled) { "<Path Data=`"$d`" Fill=`"#$Color`"/>" }
        else { "<Path Data=`"$d`" Stroke=`"#$Color`" StrokeThickness=`"$($Stroke.ToString($inv))`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`" StrokeLineJoin=`"Round`"/>" }
    }
    "<Viewbox Width=`"$($Size.ToString($inv))`" Height=`"$($Size.ToString($inv))`" $Extra><Canvas Width=`"24`" Height=`"24`">$(-join $paths)</Canvas></Viewbox>"
}

# ----------------------------------------------------------------- pieces

# What a parsed fragment needs to stand alone: the namespaces on its root.
function ConvertTo-PanelElement([string]$Xaml) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [Windows.Markup.XamlReader]::Parse(($Xaml -replace '^\s*<(\w+)', ('<$1 ' + $script:PanelNs)))
}

# The window: 14 px corners, the accent as a 2 px edge, 16 px of padding.
# $Resources (the kit's, from Get-KitResourcesXaml) go to the root grid, so
# the body can use them. This module imports nothing of Surfaces, so that
# Surfaces may use it.
function Get-PanelWindowXaml($p, [string]$Title, [int]$Width, [int]$Height, [string]$Body, [int]$Padding = 16, [string]$Resources = '') {
    $t = Get-PanelTokens $p
    @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(ConvertTo-PanelXml $Title)" Width="$Width" Height="$Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True" ShowInTaskbar="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="13" Foreground="#$($t.text)">
  <Border Background="#$($t.bg)" BorderBrush="#$($t.accent)" BorderThickness="2" CornerRadius="14" Padding="$Padding" SnapsToDevicePixels="True">
    <Grid>
      <Grid.Resources>
$Resources
      </Grid.Resources>
$Body
    </Grid>
  </Border>
</Window>
"@
}

# A section's label, with a note at the right (and a count in a small pill).
function Get-PanelSectionXaml($t, [string]$Text, [string]$Note = '', [object]$Count = $null, [string]$Margin = '2,4,0,0') {
    $pill = ''
    if ($null -ne $Count) {
        $pill = "<Border Background=`"#$($t.surface)`" CornerRadius=`"8`" Padding=`"7,1`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$Count`" FontSize=`"12`" Foreground=`"#$($t.text)`"/></Border>"
    }
    $right = ''
    if ($Note) { $right = "<TextBlock DockPanel.Dock=`"Right`" Text=`"$(ConvertTo-PanelXml $Note)`" FontSize=`"12`" Foreground=`"#$($t.textSecondary)`" VerticalAlignment=`"Center`"/>" }
    "<DockPanel Margin=`"$Margin`" Height=`"20`">$right<StackPanel Orientation=`"Horizontal`"><TextBlock Text=`"$(ConvertTo-PanelXml $Text.ToUpper())`" FontSize=`"12`" FontWeight=`"Bold`" Foreground=`"#$($t.muted)`" VerticalAlignment=`"Center`"/>$pill</StackPanel></DockPanel>"
}

# A chip: a state in words with its shape (check, triangle, cross), never
# colour alone. Kind: ok, warn, alert or plain.
function Get-PanelChipXaml($t, [string]$Kind, [string]$Text, [string]$Name = '') {
    $bg = $t.surfaceAlt; $fg = $t.text; $icon = ''
    switch ($Kind) {
        'ok'    { $bg = $t.successSoft; $fg = $t.successText; $icon = Get-PanelIconXaml 'check' 12 $t.success 2.4 'Margin="0,0,5,0"' }
        'warn'  { $bg = $t.alertSoft; $fg = $t.alertText; $icon = Get-PanelIconXaml 'warn' 12 $t.alert 2.4 'Margin="0,0,5,0"' }
        'alert' { $bg = $t.alertSoft; $fg = $t.alertText; $icon = Get-PanelIconXaml 'cross' 12 $t.alert 2.4 'Margin="0,0,5,0"' }
        'plain' { $bg = $t.surface }
    }
    $n = ''
    if ($Name) { $n = " x:Name=`"$Name`"" }
    "<Border$n Height=`"22`" CornerRadius=`"11`" Padding=`"9,0`" Background=`"#$bg`" VerticalAlignment=`"Center`"><StackPanel Orientation=`"Horizontal`" VerticalAlignment=`"Center`">$icon<TextBlock Text=`"$(ConvertTo-PanelXml $Text)`" FontSize=`"12`" FontWeight=`"Bold`" Foreground=`"#$fg`" VerticalAlignment=`"Center`"/></StackPanel></Border>"
}

# A button. Kind: primary (the accent), neutral (the surface) or danger. The
# focus ring is the design's: the background colour, then the ring, outside.
function Get-PanelButtonXaml($t, [string]$Name, [string]$Text, [string]$Icon = '', [string]$Kind = 'neutral', [int]$Height = 34, [string]$Extra = '') {
    $fill = $t.neutralFill; $hover = $t.neutralHover; $fg = $t.text; $weight = 'Normal'
    switch ($Kind) {
        'primary' { $fill = $t.actionFill; $hover = $t.focusRing; $fg = $t.actionText; $weight = 'Bold' }
        'danger'  { $fill = $t.alert; $hover = ConvertTo-PanelMix $t.alert 'FFFFFF' 0.15; $fg = $t.bg; $weight = 'Bold' }
    }
    $ic = ''
    $label = ''
    $pad = '12,0'
    if ($Icon) {
        $gap = '0,0,8,0'
        if (-not $Text) { $gap = '0'; $pad = '0' }
        $ic = Get-PanelIconXaml $Icon 14 $fg 2 "Margin=`"$gap`" VerticalAlignment=`"Center`""
    }
    if ($Text) { $label = "<TextBlock Text=`"$(ConvertTo-PanelXml $Text)`" Foreground=`"{TemplateBinding Foreground}`" VerticalAlignment=`"Center`"/>" }
    $n = ''
    if ($Name) { $n = " x:Name=`"$Name`"" }
    @"
<Button$n Height="$Height" Cursor="Hand" FocusVisualStyle="{x:Null}" Foreground="#$fg" Background="#$fill" FontSize="12" FontWeight="$weight" $Extra>
  <Button.Template><ControlTemplate TargetType="Button">
    <Grid>
      <Border x:Name="Ring" Margin="-4" CornerRadius="14" BorderThickness="2" BorderBrush="#$($t.focusRing)" Visibility="Collapsed"/>
      <Border x:Name="Gap" Margin="-2" CornerRadius="12" BorderThickness="2" BorderBrush="#$($t.bg)" Visibility="Collapsed"/>
      <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="$pad">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">$ic$label</StackPanel>
      </Border>
    </Grid>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$hover"/></Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Ring" Property="Visibility" Value="Visible"/><Setter TargetName="Gap" Property="Visibility" Value="Visible"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Button.Template>
</Button>
"@
}

# A card: the surface block of 12 px corners. A level other than ok draws the
# bar down its left edge, in the alert colour.
function Get-PanelCardXaml($t, [string]$Content, [string]$Level = 'ok', [string]$Margin = '0') {
    $edge = '0'; $pad = '12'; $brush = 'Transparent'
    if ($Level -ne 'ok') { $edge = '3,0,0,0'; $pad = '9,12,12,12'; $brush = "#$($t.alert)" }
    "<Border Margin=`"$Margin`" Background=`"#$($t.surface)`" CornerRadius=`"12`" BorderThickness=`"$edge`" BorderBrush=`"$brush`" Padding=`"$pad`">$Content</Border>"
}

# A tile with an icon: 38 px, the surface-alt colour, the accent icon.
function Get-PanelTileXaml($t, [string]$Icon, [int]$Size = 38, [string]$Extra = '') {
    "<Border Width=`"$Size`" Height=`"$Size`" CornerRadius=`"10`" Background=`"#$($t.surfaceAlt)`" VerticalAlignment=`"Top`" $Extra><Grid HorizontalAlignment=`"Center`" VerticalAlignment=`"Center`">$(Get-PanelIconXaml $Icon 18 $t.accent)</Grid></Border>"
}

Export-ModuleMember -Function ConvertTo-PanelMix, Get-PanelTokens, Get-PanelIconXaml, ConvertTo-PanelElement, Get-PanelWindowXaml,
    Get-PanelSectionXaml, Get-PanelChipXaml, Get-PanelButtonXaml, Get-PanelCardXaml, Get-PanelTileXaml
