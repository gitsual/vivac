# vivac's own surfaces: the help pane, the power menu, the theme picker, the
# notification and the clipboard forwarder. bin/vivac.ps1 dispatches to these;
# the tests build each window without showing it.
#
# Every window here is WPF, which ships with Windows, painted at start from
# the palette the settings file names: a theme switch reaches these too,
# without a template, because they read the palette rather than a render.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bridge.psm1')
Import-Module (Join-Path $PSScriptRoot 'Mouse.psm1')
Import-Module (Join-Path $PSScriptRoot 'Phone.psm1')
Import-Module (Join-Path $PSScriptRoot 'Hermes.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')
Import-Module (Join-Path $PSScriptRoot 'SoundLogic.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClipLogic.psm1')
Import-Module (Join-Path $PSScriptRoot 'Hover.psm1')

$root = Split-Path -Parent $PSScriptRoot
$script:VivacEntry = Join-Path $root 'bin\vivac.ps1'

# Settings and strings are read again each time a surface opens, not once at
# import: the resident host (bin/vivac-daemon.ps1) lives through theme and
# language switches and must paint the current ones.
function Update-SurfaceContext {
    $script:settings = Read-VivacSettings
    [void](Import-VivacStrings $script:settings['language'])
}
Update-SurfaceContext

function Get-Palette {
    try { (Read-VivacTheme $settings['theme']).Tokens } catch { (Read-VivacTheme (Get-VivacDefaultTheme)).Tokens }
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

# One instance per surface: pressing the key again while it is open does not
# stack a second window.
function Enter-SingleInstance([string]$Name) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, "Local\vivac-$Name", [ref]$created)
    if (-not $created) { exit 0 }
}

# Windows keeps the keyboard with the foreground application and refuses a
# process started in the background (as these are, by GlazeWM or the bar) the
# right to take it. Attaching to the input of the window that has it lifts the
# refusal for one call; without this the pane opens, but Esc and the arrows
# keep going to whatever was focused before.
function Set-VivacForeground($Window) {
    if (-not ('Vivac.Focus' -as [type])) {
        Add-Type -Namespace Vivac -Name Focus -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
'@
    }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
    $fg = [Vivac.Focus]::GetForegroundWindow()
    $theirs = [Vivac.Focus]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $ours = [Vivac.Focus]::GetCurrentThreadId()
    $attached = $false
    if ($theirs -and $theirs -ne $ours) { $attached = [Vivac.Focus]::AttachThreadInput($ours, $theirs, $true) }
    try {
        [void][Vivac.Focus]::BringWindowToTop($hwnd)
        [void][Vivac.Focus]::SetForegroundWindow($hwnd)
        [void]$Window.Activate()
    } finally {
        if ($attached) { [void][Vivac.Focus]::AttachThreadInput($ours, $theirs, $false) }
    }
}

# The rule of the panel about to be built, when the host is opening it
# because the pointer rested on its bar button. New-VivacWindow takes it (and
# leaves none behind), so no panel needs to know about hover.
$script:HoverNext = $null
function Set-VivacHoverNext($State) { $script:HoverNext = $State }

# Hover mode for one window: the pointer's comings and goings and the first
# click or key feed the rule, and a timer asks it whether the panel is due
# to close. Only windows opened by hover get this; one opened by a click is
# pinned from the start, as it always was.
function Connect-VivacHover($Window, $State) {
    $Window.Resources['vivac.hover'] = $State
    $Window.Add_MouseEnter({ param($s) $s.Resources['vivac.hover'].PointerIn((Get-VivacHoverNow)) })
    $Window.Add_MouseLeave({ param($s) $s.Resources['vivac.hover'].PointerOut((Get-VivacHoverNow)) })
    $Window.Add_PreviewMouseDown({ param($s) $s.Resources['vivac.hover'].Pin() })
    $Window.Add_PreviewKeyDown({ param($s) $s.Resources['vivac.hover'].Pin() })
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Tag = $Window
    $timer.Add_Tick({
            param($t)
            $w = $t.Tag
            try { if ($w.Resources['vivac.hover'].Tick((Get-VivacHoverNow))) { $t.Stop(); $w.Close() } } catch { $t.Stop() }
        })
    $Window.Resources['vivac.hoverTimer'] = $timer
    $Window.Add_Closed({ param($s) $s.Resources['vivac.hoverTimer'].Stop() })
    $timer.Start()
}

function New-VivacWindow([string]$Xaml) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $window = [Windows.Markup.XamlReader]::Parse($Xaml)
    # Keys go to the focused element; a surface with nothing focusable (the
    # power menu is only buttons drawn as borders) takes the focus itself, or
    # Esc and the arrows would go nowhere.
    $window.Focusable = $true
    $window.Add_ContentRendered({
        param($s)
        $s.Resources['vivac.shownAt'] = [Environment]::TickCount
        Set-VivacForeground $s
        if (-not [Windows.Input.Keyboard]::FocusedElement) { [void][Windows.Input.Keyboard]::Focus($s) }
    })
    # Close on losing focus, as a launcher does: a surface left behind another
    # window is one the next keypress cannot find. Not in its first moments,
    # though: the focus can be taken from it while it opens (the window the
    # key was pressed in, the shell settling the foreground, a window manager
    # catching up), and that closed the menu as soon as it appeared. Then the
    # focus is taken back instead.
    $window.Add_Deactivated({
            param($s)
            $at = $s.Resources['vivac.shownAt']
            if ($null -eq $at -or [Environment]::TickCount - [int]$at -lt 1500) {
                [void]$s.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,
                    [Action[object]] { param($w) try { if ($w.IsVisible) { Set-VivacForeground $w } } catch { } }, $s)
                return
            }
            # A panel you work beside (vivac ask) sets vivac.keep and stays.
            if ($s.Resources['vivac.keep']) { return }
            try { $s.Close() } catch { }
        })
    $hover = $script:HoverNext
    $script:HoverNext = $null
    if ($hover) { Connect-VivacHover $window $hover }
    $window
}

function Get-WindowXaml([string]$Title, [int]$Width, [int]$Height, [string]$Body) {
    $p = Get-Palette
    @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(ConvertTo-XmlText $Title)" Width="$Width" Height="$Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True" ShowInTaskbar="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="14" Foreground="#$($p['COLOR_FG'])">
  <Border Background="#F2$($p['COLOR_BG'])" BorderBrush="#$($p['COLOR_ACCENT'])" BorderThickness="2" CornerRadius="12" Padding="18">
$Body
  </Border>
</Window>
"@
}

function Invoke-Detached([string]$Script, [string[]]$Arguments) {
    $argLine = @('--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    Start-Process -FilePath 'conhost.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
}

# Another surface, through the resident host when it answers (at once), or
# started on its own when it does not (about two seconds).
function Request-VivacVerb([string]$Verb) {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', (Get-VivacPipeName), [IO.Pipes.PipeDirection]::Out)
    try {
        $client.Connect(300)
        $bytes = [Text.Encoding]::ASCII.GetBytes("$Verb`n")
        $client.Write($bytes, 0, $bytes.Length)
        return
    } catch {
    } finally { $client.Dispose() }
    Invoke-Detached $script:VivacEntry @($Verb)
}

# ------------------------------------------------------------------------ kit

# The look every surface shares, first drawn for the menu: icon tiles in the
# surface colour, rounded rows that light up under the pointer and take the
# accent bar when selected, thin scroll bars, cards, pill buttons, switches,
# and key hints as key caps at the foot. Glyphs are Segoe Fluent Icons,
# Windows 11's own icon font ($script:KitIconFont).
$script:KitIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'

function Get-KitGlyph([int]$Code) { [string][char]$Code }

# Resources for a surface's root Grid.Resources: implicit styles for scroll
# bars, list rows and sliders, and keyed ones for the rest:
#   KitCard (Border)      a block in the surface colour
#   KitButton (Button)    accent-filled, for the one thing a panel is for
#   KitGhost (Button)     surface-filled, for everything else
#   KitSwitch (ToggleButton) an on/off switch
#   KitTile (Border)      the 36 px icon tile of a row
#   B2V                   BooleanToVisibilityConverter
function Get-KitResourcesXaml($p) {
    @"
<BooleanToVisibilityConverter x:Key="B2V"/>
<Style TargetType="ScrollBar">
  <Setter Property="Width" Value="6"/>
  <Setter Property="MinWidth" Value="6"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
    <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
        <Border CornerRadius="3" Background="#$($p['COLOR_SURFACE_ALT'])"/>
      </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
    </Track>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style TargetType="ListBoxItem">
  <Setter Property="Foreground" Value="#$($p['COLOR_FG'])"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
    <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Margin="0,1" Padding="8,0">
      <Grid>
        <Border x:Name="Bar" Width="3" HorizontalAlignment="Left" Margin="-8,10,0,10" CornerRadius="2" Background="#$($p['COLOR_ACCENT'])" Visibility="Hidden"/>
        <ContentPresenter/>
      </Grid>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#66$($p['COLOR_SURFACE'])"/></Trigger>
      <Trigger Property="IsSelected" Value="True">
        <Setter TargetName="Bd" Property="Background" Value="#$($p['COLOR_SURFACE_ALT'])"/>
        <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
      </Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
$(Get-SliderStyleXaml $p)
<Style x:Key="KitCard" TargetType="Border">
  <Setter Property="Background" Value="#$($p['COLOR_SURFACE'])"/>
  <Setter Property="CornerRadius" Value="10"/>
  <Setter Property="Padding" Value="14,12"/>
  <Setter Property="Margin" Value="0,0,0,10"/>
</Style>
<Style x:Key="KitTile" TargetType="Border">
  <Setter Property="Width" Value="36"/>
  <Setter Property="Height" Value="36"/>
  <Setter Property="CornerRadius" Value="9"/>
  <Setter Property="Background" Value="#$($p['COLOR_SURFACE_ALT'])"/>
</Style>
<Style x:Key="KitButton" TargetType="Button">
  <Setter Property="Foreground" Value="#$($p['COLOR_BG'])"/>
  <Setter Property="Background" Value="#$($p['COLOR_ACCENT'])"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,7">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="KitGhost" TargetType="Button" BasedOn="{StaticResource KitButton}">
  <Setter Property="Foreground" Value="#$($p['COLOR_FG'])"/>
  <Setter Property="Background" Value="#$($p['COLOR_SURFACE_ALT'])"/>
</Style>
<Style x:Key="KitSwitch" TargetType="ToggleButton">
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
    <Border x:Name="Track" Width="40" Height="22" CornerRadius="11" Background="#$($p['COLOR_SURFACE_ALT'])">
      <Ellipse x:Name="Knob" Width="14" Height="14" Margin="4,0" HorizontalAlignment="Left" Fill="#$($p['COLOR_MUTED'])"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsChecked" Value="True">
        <Setter TargetName="Track" Property="Background" Value="#$($p['COLOR_ACCENT'])"/>
        <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
        <Setter TargetName="Knob" Property="Fill" Value="#$($p['COLOR_BG'])"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Track" Property="Opacity" Value="0.4"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
</Style>
"@
}

# The foot of a surface: what the keys do, as key caps. Pairs of key text
# (XML, so &#x2191; is fine) and label (plain text).
function Get-KitHintsXaml($p, [object[]]$Pairs) {
    $out = foreach ($pair in $Pairs) {
        "<StackPanel Orientation=`"Horizontal`" Margin=`"0,0,16,0`"><Border Background=`"#$($p['COLOR_SURFACE_ALT'])`" CornerRadius=`"4`" Padding=`"6,1`" Margin=`"0,0,6,0`"><TextBlock Text=`"$($pair[0])`" FontSize=`"11`" Foreground=`"#$($p['COLOR_FG'])`"/></Border><TextBlock Text=`"$(ConvertTo-XmlText $pair[1])`" FontSize=`"11`" Foreground=`"#$($p['COLOR_MUTED'])`" VerticalAlignment=`"Center`"/></StackPanel>"
    }
    "<WrapPanel>$(-join $out)</WrapPanel>"
}

# A panel: the header (icon tile, title, a line under it named Subtitle, and
# a slot on the right named HeaderRight for a switch or a button), the body,
# and the key hints at the foot.
function Get-KitPanelXaml($p, [int]$Glyph, [string]$Title, [string]$Body, [object[]]$Hints = @()) {
    $foot = ''
    if ($Hints.Count) { $foot = "<Border DockPanel.Dock=`"Bottom`" Margin=`"0,12,0,0`">$(Get-KitHintsXaml $p $Hints)</Border>" }
    @"
<Grid>
  <Grid.Resources>
$(Get-KitResourcesXaml $p)
  </Grid.Resources>
  <DockPanel>
    <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Width="42" Height="42" CornerRadius="21" Background="#$($p['COLOR_ACCENT'])">
        <TextBlock Text="$(Get-KitGlyph $Glyph)" FontFamily="$script:KitIconFont" FontSize="19" Foreground="#$($p['COLOR_BG'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
        <TextBlock Text="$(ConvertTo-XmlText $Title)" FontSize="16" FontWeight="SemiBold" Foreground="#$($p['COLOR_FG'])"/>
        <TextBlock x:Name="Subtitle" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <StackPanel x:Name="HeaderRight" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center"/>
    </Grid>
    $foot
    $Body
  </DockPanel>
</Grid>
"@
}

# A drop-down from the bar's right end rather than a dialog in the middle.
function Set-KitDropDown($Window) {
    $area = [Windows.SystemParameters]::WorkArea
    $Window.WindowStartupLocation = 'Manual'
    $Window.SizeToContent = 'Height'
    $Window.MaxHeight = $area.Height - 30
    $Window.Left = $area.Right - $Window.Width - 15
    $Window.Top = $area.Top + 15
}

# A row built in code, in the look of the menu's: icon tile, name, a muted
# line under it, and whatever goes on the right (a switch, a button, text).
function New-KitRow($p, [int]$Glyph, [string]$Name, [string]$Sub = '', $Right = $null, [string]$GlyphColor = '') {
    if (-not $GlyphColor) { $GlyphColor = $p['COLOR_ACCENT'] }
    $g = New-Object Windows.Controls.Grid
    $g.MinHeight = 48
    foreach ($w in '44', '*', 'Auto') {
        $c = New-Object Windows.Controls.ColumnDefinition
        $c.Width = [Windows.GridLengthConverter]::new().ConvertFromString($w)
        $g.ColumnDefinitions.Add($c)
    }
    $tile = New-Object Windows.Controls.Border
    $tile.Width = 36; $tile.Height = 36; $tile.CornerRadius = 9; $tile.HorizontalAlignment = 'Left'
    $tile.Background = "#$($p['COLOR_SURFACE_ALT'])"
    $gt = New-Object Windows.Controls.TextBlock
    $gt.Text = Get-KitGlyph $Glyph; $gt.FontFamily = $script:KitIconFont; $gt.FontSize = 16
    $gt.Foreground = "#$GlyphColor"; $gt.HorizontalAlignment = 'Center'; $gt.VerticalAlignment = 'Center'
    $tile.Child = $gt
    [void]$g.Children.Add($tile)
    $stack = New-Object Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'; $stack.Margin = '8,0,8,0'
    $n = New-Object Windows.Controls.TextBlock
    $n.Text = $Name; $n.FontSize = 14; $n.TextTrimming = 'CharacterEllipsis'; $n.Foreground = "#$($p['COLOR_FG'])"
    [void]$stack.Children.Add($n)
    $s = New-Object Windows.Controls.TextBlock
    $s.Text = $Sub; $s.FontSize = 11; $s.TextTrimming = 'CharacterEllipsis'; $s.Foreground = "#$($p['COLOR_MUTED'])"
    if (-not $Sub) { $s.Visibility = 'Collapsed' }
    [void]$stack.Children.Add($s)
    [Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$g.Children.Add($stack)
    if ($Right) {
        $Right.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($Right, 2)
        [void]$g.Children.Add($Right)
    }
    # The parts a caller may want to change later.
    $g.Tag = @{ Glyph = $gt; Name = $n; Sub = $s; Tile = $tile }
    $g
}

# --------------------------------------------------------------------- notify

# vivac's own notification, in the palette, as dunst draws them in the
# source: top right under the bar, gone after a few seconds or at a click.
# It never takes the focus from what you were doing. The same card carries
# what other programs post (lib/Toasts.psm1): the program's icon and name,
# the time, the title and the text, a close mark, and a line along the foot
# that runs out with the time left. $Image is a picture file the program sent
# (its logo), $IconKey a shell name to take the icon from, $Glyph a fallback.
# The window's Tag holds the parts a caller drives: Close, Progress, Card.
function New-VivacNotification([string]$Title, [string]$Body, [string]$App = 'vivac', [string]$Image = '', [string]$IconKey = '', [int]$Glyph = 0xEA8F) {
    Update-SurfaceContext
    $p = Get-Palette
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $bodyRow = ''
    if ($Body) {
        $bodyRow = "<TextBlock Grid.Row=`"2`" Grid.ColumnSpan=`"2`" Margin=`"0,3,0,0`" FontSize=`"12.5`" Foreground=`"#$($p['COLOR_FG'])`" Opacity=`"0.7`" TextWrapping=`"Wrap`" TextTrimming=`"CharacterEllipsis`" MaxHeight=`"68`" Text=`"$(ConvertTo-XmlText $Body)`"/>"
    }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - notification" Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="13">
  <Border x:Name="Card" Background="#F2$($p['COLOR_SURFACE'])" BorderBrush="#$($p['COLOR_BORDER_INACTIVE'])" BorderThickness="1" CornerRadius="14" Cursor="Hand">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="3"/></Grid.RowDefinitions>
      <Grid Margin="12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Width="48" Height="48" CornerRadius="12" Background="#$($p['COLOR_BG'])" VerticalAlignment="Top" HorizontalAlignment="Left">
          <Grid>
            <TextBlock x:Name="Glyph" Text="$(Get-KitGlyph $Glyph)" FontFamily="$script:KitIconFont" FontSize="20" Foreground="#$($p['COLOR_ACCENT'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Image x:Name="Icon" Width="32" Height="32" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
        </Border>
        <Grid Grid.Column="1">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock FontSize="11" Foreground="#$($p['COLOR_MUTED'])" TextTrimming="CharacterEllipsis">
            <Run Text="$(ConvertTo-XmlText $App)"/><Run Text=" &#x00B7; $((Get-Date).ToString('HH:mm'))"/>
          </TextBlock>
          <TextBlock x:Name="Close" Grid.Column="1" Text="$(Get-KitGlyph 0xE711)" FontFamily="$script:KitIconFont" FontSize="12" Foreground="#$($p['COLOR_ACCENT'])" Margin="8,1,0,0" Cursor="Hand"/>
          <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Margin="0,4,0,0" FontSize="15" FontWeight="Bold" Foreground="#$($p['COLOR_FG'])" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="44" Text="$(ConvertTo-XmlText $Title)"/>
          $bodyRow
        </Grid>
      </Grid>
      <Border x:Name="Progress" Grid.Row="1" Background="#$($p['COLOR_ACCENT'])" HorizontalAlignment="Left" Width="380" Margin="14,0,0,0" CornerRadius="2"/>
    </Grid>
  </Border>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $icon = $w.FindName('Icon')
    $glyphText = $w.FindName('Glyph')
    if ($Image -and (Test-Path -LiteralPath $Image)) {
        try {
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = New-Object Uri $Image
            $bmp.DecodePixelWidth = 64
            $bmp.CacheOption = 'OnLoad'
            $bmp.EndInit()
            $icon.Source = $bmp
            $glyphText.Visibility = 'Hidden'
        } catch { }
    }
    if (-not $icon.Source -and $IconKey) {
        try {
            Import-VivacMenu
            $src = [VivacIcons]::Get($IconKey)
            if ($src) { $icon.Source = $src; $glyphText.Visibility = 'Hidden' }
            else {
                # Not fetched yet: asked for now, picked up as soon as it is there.
                [VivacIcons]::Request($IconKey, $null)
                $poll = New-Object Windows.Threading.DispatcherTimer
                $poll.Interval = [TimeSpan]::FromMilliseconds(150)
                $poll.Tag = @{ Key = $IconKey; Icon = $icon; Glyph = $glyphText; Left = 20 }
                $poll.Add_Tick({
                        param($s)
                        $t = $s.Tag; $t.Left--
                        $got = [VivacIcons]::Get($t.Key)
                        if ($got) { $t.Icon.Source = $got; $t.Glyph.Visibility = 'Hidden' }
                        if ($got -or $t.Left -le 0 -or [VivacIcons]::IsMissing($t.Key)) { $s.Stop() }
                    })
                $poll.Start()
            }
        } catch { }
    }
    $w.Tag = @{ Close = $w.FindName('Close'); Progress = $w.FindName('Progress'); Card = $w.FindName('Card') }
    $area = [Windows.SystemParameters]::WorkArea
    $w.WindowStartupLocation = 'Manual'
    $w.Left = $area.Right - $w.Width - 15
    $w.Top = $area.Top + 15
    $w
}

function Show-Notification([string]$Title, [string]$Body) {
    $w = New-VivacNotification $Title $Body
    $w.Add_MouseLeftButtonUp({ param($s) $s.Close() })
    $w.Add_Closed({ [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(5)
    $t.Tag = $w
    $t.Add_Tick({ param($s) $s.Stop(); $s.Tag.Close() })
    $w.Show()
    $t.Start()
    [Windows.Threading.Dispatcher]::Run()
}

# --------------------------------------------------------------- volume OSD

# The volume indicator that replaces Windows' flyout, in the capsule the Linux
# side draws (linux/lib/vivacpanel/osd.py): a badge with the speaker, the
# output's name over a bar of notches, and the level in large type. The
# resident host takes the volume keys, sets the volume, and shows this; it is
# built once and repainted from the current palette each time, and hides
# itself after a second and a half without a change.
function New-VivacVolumeOsd {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - volume" Width="380" Height="72"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="14" UseLayoutRounding="True">
  <Border x:Name="Frame" BorderThickness="2" CornerRadius="36" Padding="18,0,18,0">
    <Grid VerticalAlignment="Center">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border x:Name="Badge" Grid.Column="0" Width="40" Height="40" CornerRadius="20" VerticalAlignment="Center">
        <TextBlock x:Name="Glyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="14,0,10,0" VerticalAlignment="Center">
        <TextBlock x:Name="Name" FontSize="12" TextTrimming="CharacterEllipsis"/>
        <Border x:Name="BarHost" Margin="0,6,0,0" Height="14"/>
      </StackPanel>
      <TextBlock x:Name="Level" Grid.Column="2" MinWidth="56" TextAlignment="Right" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid>
  </Border>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $w.WindowStartupLocation = 'Manual'
    $hide = New-Object Windows.Threading.DispatcherTimer
    $hide.Interval = [TimeSpan]::FromMilliseconds(1500)
    $hide.Tag = $w
    $hide.Add_Tick({ param($s) $s.Stop(); $s.Tag.Hide() })
    [pscustomobject]@{ Window = $w; Timer = $hide; Bar = $null }
}

# The default output's name for the capsule, asked of Core Audio at most once
# in a few seconds: holding a volume key shows this thirty times a second.
$script:OsdName = ''
$script:OsdNameAt = [datetime]::MinValue
function Get-VivacOsdName {
    if (([datetime]::Now - $script:OsdNameAt).TotalSeconds -gt 3) {
        $script:OsdNameAt = [datetime]::Now
        $name = ''
        try { if ('VivacAudio' -as [type]) { $name = [VivacAudio]::DefaultName(0) } } catch { }
        $script:OsdName = Get-SoundShortName $name
    }
    $script:OsdName
}

function Show-VivacVolumeOsd($Osd, [int]$Level, [bool]$Muted) {
    Update-SurfaceContext
    $p = Get-Palette
    $t = Get-KitTokens $p
    $w = $Osd.Window
    $w.FindName('Frame').Background = New-KitBrush "F7$($t['bg'])"
    $w.FindName('Frame').BorderBrush = New-KitBrush $t['accent']
    $w.FindName('Badge').Background = New-KitBrush $t['surface']
    $glyph = $w.FindName('Glyph')
    $glyph.Foreground = New-KitBrush $(if ($Muted) { $t['alert'] } else { $t['accent'] })
    # Segoe Fluent Icons: mute, then speaker with no, one, two, three waves.
    $glyph.Text = if ($Muted) { [char]0xE74F } elseif ($Level -eq 0) { [char]0xE992 } elseif ($Level -lt 34) { [char]0xE993 } elseif ($Level -lt 67) { [char]0xE994 } else { [char]0xE995 }
    $name = $w.FindName('Name')
    $name.Foreground = New-KitBrush $t['textSecondary']
    $name.Text = Get-VivacOsdName
    $name.Visibility = if ($name.Text) { 'Visible' } else { 'Collapsed' }
    if (-not $Osd.Bar) {
        $Osd.Bar = New-KitNotchBar $t 26 14
        $w.FindName('BarHost').Child = $Osd.Bar
    }
    $Osd.Bar.Tag.Tokens = $t
    [void](Set-KitNotchBar $Osd.Bar ([Math]::Min(100, $Level) / 100) $Muted)
    $label = $w.FindName('Level')
    $label.Inlines.Clear()
    if ($Muted) {
        $label.FontSize = 12; $label.FontWeight = 'Normal'
        $label.Foreground = New-KitBrush $t['alert']
        [void]$label.Inlines.Add((New-Object Windows.Documents.Run (T 'osd.muted')))
    } else {
        $label.FontSize = 24; $label.FontWeight = 'Bold'
        $label.Foreground = New-KitBrush $t['text']
        [void]$label.Inlines.Add((New-Object Windows.Documents.Run "$Level"))
        $unit = New-Object Windows.Documents.Run '%'
        $unit.FontSize = 14; $unit.FontWeight = 'Normal'; $unit.Foreground = New-KitBrush $t['textSecondary']
        [void]$label.Inlines.Add($unit)
    }
    # Bottom centre of the primary work area, where Windows puts its own.
    $area = [Windows.SystemParameters]::WorkArea
    $w.Left = $area.Left + ($area.Width - $w.Width) / 2
    $w.Top = $area.Bottom - $w.Height - 72
    if (-not $w.IsVisible) { $w.Show() }
    $Osd.Timer.Stop()
    $Osd.Timer.Start()
}

# ------------------------------------------------------------------ clipboard

# With Alt as the modifier, Alt+V forwards here and this presses Win+V. With
# Win as the modifier the binding is not rendered at all: Win+V is already it.
function Open-ClipboardHistory {
    if (-not ('Vivac.Keys' -as [type])) {
        Add-Type -Namespace Vivac -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
    }
    # Let go of the Alt that triggered this first, or Windows sees Alt+Win+V.
    foreach ($vk in 0x12, 0xA4, 0xA5) { [Vivac.Keys]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero) }
    [Vivac.Keys]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
    [Vivac.Keys]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
    [Vivac.Keys]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
    [Vivac.Keys]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
}

# ------------------------------------------------------------------ help pane

# The live bindings, read from the deployed GlazeWM config rather than from
# the template: what the pane shows is what the keys do right now.
function Get-LiveBindings {
    $cfg = Join-Path (Get-VivacPaths).Profile '.glzr\glazewm\config.yaml'
    $binds = @()
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in [IO.File]::ReadAllLines($cfg)) {
            if ($line -match "^\s*bindings:\s*\[(.*)\]") {
                $binds += @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'", '"') } | Where-Object { $_ })
            }
        }
    }
    $binds
}

function Show-Help([string]$StartPane = 'wm', [switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'help' }
    $surfaceName = 'help'
    $p = Get-Palette
    $mod = $settings['mod']
    $helpRows = Read-VivacHelpRegistry
    $panes = @('wm', 'browser', 'shell', 'editor', 'system')

    # A live binding the registry does not describe is shown, marked, rather
    # than dropped: the pane must never hide a key that does something.
    $known = @{}
    foreach ($r in $helpRows | Where-Object { $_.Pane -eq 'wm' }) { $known[($r.Bind -replace '^MOD', $mod).ToLowerInvariant()] = $true }
    $unregistered = @(Get-LiveBindings | Where-Object { -not $known.ContainsKey($_.ToLowerInvariant()) })

    $tabs = ''
    for ($i = 0; $i -lt $panes.Count; $i++) {
        $tabs += "<TextBlock x:Name='Tab$i' Margin='0,0,18,0' Text='F$($i + 1)  $(ConvertTo-XmlText (T "help.pane.$($panes[$i])"))'/>"
    }
    $body = @"
<DockPanel>
  <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,12">$tabs</StackPanel>
  <TextBox x:Name="Filter" DockPanel.Dock="Top" Margin="0,0,0,10" Padding="8,6" Background="#$($p['COLOR_SURFACE'])"
           Foreground="#$($p['COLOR_FG'])" CaretBrush="#$($p['COLOR_ACCENT'])" BorderBrush="#$($p['COLOR_MUTED'])" BorderThickness="0,0,0,2"/>
  <TextBlock DockPanel.Dock="Bottom" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#$($p['COLOR_MUTED'])" Text="$(ConvertTo-XmlText (T 'help.hint'))"/>
  <ListBox x:Name="Rows" Background="Transparent" BorderThickness="0" Foreground="#$($p['COLOR_FG'])"
           ScrollViewer.HorizontalScrollBarVisibility="Disabled">
    <ListBox.Resources>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#$($p['COLOR_FG'])"/>
    </ListBox.Resources>
  </ListBox>
</DockPanel>
"@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - help' 900 640 $body)
    $rows = $window.FindName('Rows')
    $filter = $window.FindName('Filter')
    $state = @{ Pane = [Math]::Max(0, [array]::IndexOf($panes, $StartPane)) }

    $render = {
        $pane = $panes[$state.Pane]
        for ($i = 0; $i -lt $panes.Count; $i++) {
            $tab = $window.FindName("Tab$i")
            if ($i -eq $state.Pane) { $tab.Foreground = "#$($p['COLOR_ACCENT'])"; $tab.TextDecorations = 'Underline' }
            else { $tab.Foreground = "#$($p['COLOR_FG_DIM'])"; $tab.TextDecorations = $null }
        }
        $rows.Items.Clear()
        $needle = $filter.Text.Trim().ToLowerInvariant()
        $items = @()
        foreach ($r in $helpRows | Where-Object { $_.Pane -eq $pane }) {
            $items += [pscustomobject]@{ Key = (Format-VivacBind $r.Bind $mod); Text = (T $r.Label); Row = $r }
        }
        if ($pane -eq 'wm') {
            foreach ($b in $unregistered) { $items += [pscustomobject]@{ Key = $b; Text = 'UNREGISTERED'; Row = $null } }
        }
        foreach ($it in $items) {
            if ($needle -and ("$($it.Key) $($it.Text)").ToLowerInvariant().IndexOf($needle) -lt 0) { continue }
            $line = New-Object Windows.Controls.TextBlock
            $k = New-Object Windows.Documents.Run (('{0,-22}' -f $it.Key))
            $k.Foreground = "#$($p['COLOR_ACCENT'])"
            $t = New-Object Windows.Documents.Run $it.Text
            if (-not $it.Row) { $t.Foreground = "#$($p['COLOR_URGENT'])" }
            [void]$line.Inlines.Add($k); [void]$line.Inlines.Add($t)
            $line.Tag = $it.Row
            $line.Padding = '6,3'
            [void]$rows.Items.Add($line)
        }
        if ($rows.Items.Count) { $rows.SelectedIndex = 0 }
    }

    # Acting on a row runs the registry's action column, never anything read
    # out of a translation: a label can change what it says, not what it does.
    $act = {
        $sel = $rows.SelectedItem
        if (-not $sel -or -not $sel.Tag) { return }
        $r = $sel.Tag
        $window.Close()
        switch ($r.Type) {
            'vivac' { Request-VivacVerb $r.Action }
            'glazewm' {
                if ($r.Action -match '^shell-exec vivac (\w+)$') { Request-VivacVerb $Matches[1] }
                else {
                    Import-Module (Join-Path $root 'lib\Apps.psm1') -Force
                    [void](Invoke-GlazeWM (@('command') + ($r.Action -split ' ')))
                }
            }
            'doc' {
                $file = Join-Path $root (($r.Action -split '#')[0])
                if (Test-Path -LiteralPath $file) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`"" }
            }
        }
    }

    $filter.Add_TextChanged({ & $render })
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { $window.Close(); $e.Handled = $true; return }
        if ($k -match '^F([1-5])$') { $state.Pane = [int]$Matches[1] - 1; & $render; $e.Handled = $true; return }
        if ($k -eq 'Tab') { $state.Pane = ($state.Pane + 1) % $panes.Count; & $render; $e.Handled = $true; return }
        if ($k -eq 'Down' -and $rows.SelectedIndex -lt $rows.Items.Count - 1) { $rows.SelectedIndex++; $rows.ScrollIntoView($rows.SelectedItem); $e.Handled = $true; return }
        if ($k -eq 'Up' -and $rows.SelectedIndex -gt 0) { $rows.SelectedIndex--; $rows.ScrollIntoView($rows.SelectedItem); $e.Handled = $true; return }
        if ($k -eq 'Return') { & $act; $e.Handled = $true; return }
    })
    $rows.Add_MouseDoubleClick({ & $act })
    $window.Add_ContentRendered({ $filter.Focus() | Out-Null })
    & $render
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# ----------------------------------------------------------------- power menu

function Show-Power([switch]$NoShow, [hashtable]$Registry, [string]$Arm) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'power' }
    $surfaceName = 'power'
    $p = Get-Palette
    $t = Get-PanelTokens $p
    # Segoe Fluent Icons ships with Windows 11; the glyphs are its own. Danger
    # entries wear the alert bar under the tile, as the design's.
    $entries = @(
        @{ Id = 'lock'; Glyph = [char]0xE72E; Confirm = $false; Danger = $false },
        @{ Id = 'logout'; Glyph = [char]0xF3B1; Confirm = $true; Danger = $false },
        @{ Id = 'sleep'; Glyph = [char]0xE708; Confirm = $false; Danger = $false },
        @{ Id = 'restart'; Glyph = [char]0xE777; Confirm = $true; Danger = $true },
        @{ Id = 'shutdown'; Glyph = [char]0xE7E8; Confirm = $true; Danger = $true }
    )
    if (Test-VivacRebootOther) { $entries += @{ Id = 'other'; Glyph = [char]0xE895; Confirm = $true; Danger = $false } }
    $cells = ''
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $iconColor = $(if ($e.Danger) { $t.alertText } else { $t.accent })
        $bar = ''
        if ($e.Danger) { $bar = "<Border Height=`"3`" CornerRadius=`"2`" Margin=`"18,0,18,0`" VerticalAlignment=`"Bottom`" Background=`"#$($t.alert)`"/>" }
        $cells += @"
<Border x:Name="B$i" Height="160" Margin="5" CornerRadius="12" Background="#$($t.surface)" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand">
  <Grid>
    <StackPanel VerticalAlignment="Center">
      <TextBlock HorizontalAlignment="Center" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="32" Foreground="#$iconColor" Text="$($e.Glyph)"/>
      <TextBlock x:Name="L$i" HorizontalAlignment="Center" Margin="0,14,0,0" FontSize="14" FontWeight="Bold" Foreground="#$($t.text)" Text="$(ConvertTo-XmlText (T "power.$($e.Id)"))"/>
      <Border HorizontalAlignment="Center" Margin="0,12,0,0" CornerRadius="6" Padding="7,1" BorderThickness="1" BorderBrush="#$($t.line)"><TextBlock FontSize="12" Foreground="#$($t.textSecondary)" Text="$($i + 1)"/></Border>
    </StackPanel>
    $bar
  </Grid>
</Border>
"@
    }
    $ret = [string][char]0x23CE
    $arrows = [string][char]0x2190 + [string][char]0x2192
    $strip = @"
<Border x:Name="Strip" Visibility="Collapsed" Margin="5,6,5,0" CornerRadius="10" Padding="12,8" Background="#$($t.alertSoft)" BorderThickness="1" BorderBrush="#$($t.alert)">
  <DockPanel>
    <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center">$(Get-KitHintsXamlV2 $t @(@($ret, (T 'power.key.confirm')), @('Esc', (T 'power.key.cancel'))))</StackPanel>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">$(Get-PanelIconXaml 'warn' 18 $t.alert 2 'Margin="0,0,10,0"')<TextBlock x:Name="StripText" FontSize="14" FontWeight="Bold" Foreground="#$($t.alertText)" VerticalAlignment="Center"/></StackPanel>
  </DockPanel>
</Border>
"@
    $foot = "<Border Margin='0,12,0,0' Padding='2,8,0,0' BorderBrush='#$($t.line)' BorderThickness='0,1,0,0'>$(Get-KitHintsXamlV2 $t @(@("1-$($entries.Count)", (T 'power.key.choose')), @($arrows, (T 'power.key.move')), @($ret, (T 'power.key.activate')), @('Esc', (T 'power.key.close'))))</Border>"
    $body = "<StackPanel><UniformGrid Columns=`"3`">$cells</UniformGrid>$strip$foot</StackPanel>"
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - power' 820 $body)
    $strip = $window.FindName('Strip'); $stripText = $window.FindName('StripText')
    $state = @{ Index = 0; Armed = -1 }
    # Opened armed (the switch key): that entry is selected and already asks
    # for its confirmation, so one more press carries it out.
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($Arm -and $entries[$i].Id -eq $Arm -and $entries[$i].Confirm) { $state.Index = $i; $state.Armed = $i }
    }

    $paint = {
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $b = $window.FindName("B$i")
            if ($i -eq $state.Index) { $b.BorderBrush = "#$($t.focusRing)"; $b.Background = "#$($t.surfaceAlt)" }
            else { $b.BorderBrush = 'Transparent'; $b.Background = "#$($t.surface)" }
        }
        if ($state.Armed -ge 0) { $strip.Visibility = 'Visible'; $stripText.Text = T "power.ask.$($entries[$state.Armed].Id)" }
        else { $strip.Visibility = 'Collapsed' }
    }

    # Ending the session asks first: the first press arms the entry, the
    # second carries it out.
    $run = {
        param($i)
        $e = $entries[$i]
        if ($e.Confirm -and $state.Armed -ne $i) { $state.Armed = $i; $state.Index = $i; & $paint; return }
        $window.Close()
        switch ($e.Id) {
            'lock'     { Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation' }
            'logout'   { Start-Process shutdown.exe -ArgumentList '/l' -WindowStyle Hidden }
            'sleep'    { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) }
            'restart'  { Start-Process shutdown.exe -ArgumentList '/r', '/t', '0' -WindowStyle Hidden }
            'shutdown' { Start-Process shutdown.exe -ArgumentList '/s', '/t', '0' -WindowStyle Hidden }
            'other'    { Invoke-BridgeAction 'reboot-other' }
        }
    }

    for ($i = 0; $i -lt $entries.Count; $i++) {
        $idx = $i
        $window.FindName("B$i").Add_MouseLeftButtonUp({ & $run $idx }.GetNewClosure())
    }
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { if ($state.Armed -ge 0) { $state.Armed = -1; & $paint } else { $window.Close() }; return }
        $to = $state.Index
        if ($k -eq 'Left') { $to-- } elseif ($k -eq 'Right') { $to++ } elseif ($k -eq 'Up') { $to -= 3 } elseif ($k -eq 'Down') { $to += 3 }
        if ($to -ne $state.Index) {
            if ($to -ge 0 -and $to -lt $entries.Count) { $state.Index = $to; $state.Armed = -1; & $paint }
            return
        }
        if (($k -match '^D([1-9])$' -or $k -match '^NumPad([1-9])$') -and [int]$Matches[1] -le $entries.Count) { & $run ([int]$Matches[1] - 1); return }
        if ($k -eq 'Return' -or $k -eq 'Space') { & $run $state.Index; return }
    })
    & $paint
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# --------------------------------------------------------------- theme picker

# The catalogue itself, read from data/themes/ at every start, never a copy
# of it. Each row carries the palette's own colours as swatches.
function Show-ThemePicker([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'theme' }
    $surfaceName = 'theme'
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $current = $settings['theme']
    $names = @(Get-VivacCatalogue)
    $ret = [string][char]0x23CE
    $arrows = [string][char]0x2190 + [string][char]0x2191 + [string][char]0x2193 + [string][char]0x2192
    $hints = @(@($arrows, (T 'theme.key.move')), @($ret, (T 'theme.key.apply')), @('I', (T 'theme.key.picture')), @('Esc', (T 'theme.key.close')))
    $body = @"
<StackPanel>
  <UniformGrid x:Name="Cards" Columns="4"/>
  <Border x:Name="FromImage" Margin="4,10,4,0" CornerRadius="12" Padding="12" Background="#$($t.surface)" Cursor="Hand">
    <DockPanel>
      <Border DockPanel.Dock="Right" VerticalAlignment="Center" CornerRadius="6" Padding="7,1" BorderThickness="1" BorderBrush="#$($t.line)"><TextBlock FontSize="12" Text="I" Foreground="#$($t.text)"/></Border>
      <Border Width="38" Height="38" CornerRadius="10" Background="#$($t.surfaceAlt)"><TextBlock FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="18" Foreground="#$($t.accent)" Text="$([char]0xEB9F)" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <StackPanel Margin="12,0" VerticalAlignment="Center"><TextBlock FontSize="14" FontWeight="Bold" Foreground="#$($t.text)" Text="$(ConvertTo-XmlText (T 'picture.menu'))"/><TextBlock FontSize="12" Foreground="#$($t.textSecondary)" TextTrimming="CharacterEllipsis" Text="$(ConvertTo-XmlText (T 'theme.from_image_sub'))"/></StackPanel>
    </DockPanel>
  </Border>
</StackPanel>
"@
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - theme' 820 (Get-KitPanelXamlV2 $t ([string][char]0xE790) (T 'theme.title') $body $hints))
    $cards = $window.FindName('Cards')
    $tok = { param($th, $k, $fb) if ($th.Tokens.Contains($k) -and $th.Tokens[$k]) { [string]$th.Tokens[$k] } else { $fb } }
    $currentTheme = $null
    $items = @()
    foreach ($name in $names) {
        $th = Read-VivacTheme $name
        if ($name -eq $current) { $currentTheme = $th }
        $bg = & $tok $th 'COLOR_BG' $t.bg; $acc = & $tok $th 'COLOR_ACCENT' $t.accent
        $sa = & $tok $th 'COLOR_SURFACE_ALT' $t.surfaceAlt; $sf = & $tok $th 'COLOR_SURFACE' $t.surface
        $dots = foreach ($k in 'COLOR_URGENT', 'COLOR_OK', 'COLOR_INFO', 'COLOR_ACCENT', 'COLOR_FG') { "<Ellipse Width=`"13`" Height=`"13`" Margin=`"0,0,6,0`" Fill=`"#$(& $tok $th $k $t.muted)`"/>" }
        $use = ''
        if ($name -eq $current) { $use = "<TextBlock DockPanel.Dock=`"Right`" FontSize=`"11`" Foreground=`"#$($t.textSecondary)`" VerticalAlignment=`"Bottom`" Text=`"$([char]0x2606) $(ConvertTo-XmlText (T 'theme.in_use'))`"/>" }
        $xaml = @"
<Border Margin="4" CornerRadius="12" Padding="8" Background="#$($t.surface)" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand">
  <StackPanel>
    <Border Height="100" CornerRadius="8" Background="#$bg">
      <Canvas Width="170" Height="100"><Canvas.Clip><RectangleGeometry Rect="0,0,170,100" RadiusX="8" RadiusY="8"/></Canvas.Clip>
        <Ellipse Canvas.Left="112" Canvas.Top="16" Width="30" Height="30" Fill="#$acc"/>
        <Polygon Points="0,100 0,72 45,48 80,66 120,36 170,70 170,100" Fill="#$sf"/>
        <Polygon Points="0,100 0,86 40,72 90,88 140,66 170,84 170,100" Fill="#$sa"/>
        <Rectangle Canvas.Left="6" Canvas.Top="6" Width="158" Height="5" RadiusX="2.5" RadiusY="2.5" Fill="#$bg" Stroke="#$acc" StrokeThickness="1"/>
      </Canvas>
    </Border>
    <TextBlock Margin="0,10,0,0" FontSize="14" FontWeight="Bold" Foreground="#$($t.text)" TextTrimming="CharacterEllipsis" Text="$(ConvertTo-XmlText $th.Title)"/>
    <DockPanel Margin="0,2,0,0">$use<TextBlock FontSize="12" Foreground="#$($t.textSecondary)" TextTrimming="CharacterEllipsis" Text="$(ConvertTo-XmlText $th.Essence)"/></DockPanel>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,2">$(-join $dots)</StackPanel>
  </StackPanel>
</Border>
"@
        $card = ConvertTo-PanelElement $xaml
        $card.Tag = $name
        [void]$cards.Children.Add($card)
        $items += $card
    }
    if ($currentTheme) { $window.FindName('Subtitle').Text = T 'theme.subtitle' @([string]$currentTheme.Title, [string]$currentTheme.Essence) }
    [void]$window.FindName('HeaderRight').Children.Add((ConvertTo-PanelElement (Get-PanelChipXaml $t 'plain' (T 'theme.count' @([string]$names.Count)))))
    $state = @{ Index = [Math]::Max(0, [array]::IndexOf($names, $current)) }
    $paint = {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $c = $items[$i]
            if ($i -eq $state.Index) { $c.BorderBrush = "#$($t.focusRing)" }
            elseif ([string]$c.Tag -eq $current) { $c.BorderBrush = "#$($t.accent)" }
            else { $c.BorderBrush = 'Transparent' }
        }
    }
    $fromPicture = {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = T 'picture.dialog_title'
        $dialog.Filter = (T 'picture.filter') + '|*.png;*.jpg;*.jpeg'
        $dialog.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
        if (-not $dialog.ShowDialog($window)) { return }
        $window.Close()
        # Made and worn in the background, like any switch. Start-Process
        # quotes nothing, so the path is quoted here.
        Invoke-Detached (Join-Path $root 'scripts\theme-from-image.ps1') @("`"$($dialog.FileName)`"", '-Apply')
    }
    $apply = {
        if ($state.Index -lt 0 -or $state.Index -ge $items.Count) { return }
        $window.Close()
        # Applied in the background: a theme switch restarts the bar and may
        # render a wallpaper, and the picker should not sit on screen for it.
        Invoke-Detached (Join-Path $root 'scripts\apply-theme.ps1') @('-Theme', [string]$items[$state.Index].Tag)
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $idx = $i
        $items[$i].Add_MouseLeftButtonDown({ param($s, $e) $state.Index = $idx; & $paint; if ($e.ClickCount -ge 2) { & $apply } }.GetNewClosure())
    }
    $window.FindName('FromImage').Add_MouseLeftButtonUp({ & $fromPicture })
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { $window.Close(); return }
        if ($k -eq 'Return') { & $apply; $e.Handled = $true; return }
        if ($k -eq 'I') { & $fromPicture; $e.Handled = $true; return }
        $to = $state.Index
        if ($k -eq 'Left') { $to-- } elseif ($k -eq 'Right') { $to++ } elseif ($k -eq 'Up') { $to -= 4 } elseif ($k -eq 'Down') { $to += 4 }
        if ($to -ne $state.Index -and $to -ge 0 -and $to -lt $items.Count) { $state.Index = $to; & $paint; $e.Handled = $true }
    })
    & $paint
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# ----------------------------------------------------------------- a choice

# One choice from a list, as the theme picker looks: arrows and Enter, or a
# double click; Escape chooses nothing. Returns the index, or -1. Used where
# a program asks one question (the phone to send to, bin/vivac-localsend.ps1).
function Select-VivacItem([string]$Title, [string[]]$Rows, [string]$Hint = '', [switch]$NoShow) {
    Update-SurfaceContext
    $p = Get-Palette
    $body = @"
<DockPanel>
  <TextBlock DockPanel.Dock="Top" Margin="0,0,0,12" FontSize="16" Foreground="#$($p['COLOR_ACCENT'])" Text="$(ConvertTo-XmlText $Title)"/>
  <TextBlock DockPanel.Dock="Bottom" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#$($p['COLOR_MUTED'])" Text="$(ConvertTo-XmlText $Hint)"/>
  <ListBox x:Name="Rows" Background="Transparent" BorderThickness="0" Foreground="#$($p['COLOR_FG'])">
    <ListBox.Resources>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#$($p['COLOR_FG'])"/>
    </ListBox.Resources>
  </ListBox>
</DockPanel>
"@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - choose' 560 (160 + 34 * [Math]::Min(10, $Rows.Count)) $body)
    $list = $window.FindName('Rows')
    foreach ($r in $Rows) {
        $label = New-Object Windows.Controls.TextBlock
        $label.Margin = '4,6'
        $label.Text = $r
        [void]$list.Items.Add($label)
    }
    if ($Rows.Count) { $list.SelectedIndex = 0 }
    $state = @{ Chosen = -1 }
    $pick = { $state.Chosen = $list.SelectedIndex; $window.Close() }
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { $window.Close(); return }
        if ($k -eq 'Return') { & $pick; $e.Handled = $true; return }
    })
    $list.Add_MouseDoubleClick({ & $pick })
    $window.Add_ContentRendered({ $list.Focus() | Out-Null })
    if ($NoShow) { return $window }
    [void]$window.ShowDialog()
    $state.Chosen
}

# ------------------------------------------------------------------- the menu

# The menu of the Start menu's contents: what MOD+R opens. Everything the
# Start menu and the Win+X menu reach is here, as rofi's drun is in spirit:
# one search box over every application the Start menu lists, the recent
# files its "Recommended" shows, the user folders, the main Settings pages,
# the Win+X tools and the session and power entries, each row with its icon
# and its category; a column of categories to narrow it down; what is used
# often first; and, for whatever is typed, a calculation, a run of the text,
# a search of the files and of the web.

# The rows, the shell icons and the ranking are C# (lib/VivacMenu.cs).
function Import-VivacMenu {
    if ('VivacIcons' -as [type]) { return }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $refs = @([Windows.Media.ImageSource].Assembly.Location, [Windows.DependencyObject].Assembly.Location,
        [Windows.Window].Assembly.Location, [System.Xaml.XamlType].Assembly.Location)
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacMenu.cs'))) -ReferencedAssemblies $refs -Language CSharp
}

# Get-StartApps (part of Windows) lists exactly what the Start menu's "All
# apps" does, Store apps included. It takes most of a second, so the resident
# host keeps the answer and refreshes it after each use; the icons of what it
# lists are fetched in the background from then on.
$script:StartApps = $null
function Update-VivacStartApps {
    # Windows' Run dialog is left out: what is typed in the menu runs from the
    # menu itself.
    $script:StartApps = @(Get-StartApps | Where-Object { $_.AppID -ne 'Microsoft.Windows.Shell.RunDialog' } |
        Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; AppID = $_.AppID } })
    try {
        Import-VivacMenu
        [VivacIcons]::Warm([string[]]@($script:StartApps | ForEach-Object { "shell:AppsFolder\$($_.AppID)" }))
    } catch { }
}

# Glyphs are Segoe Fluent Icons, Windows 11's own icon font.
function New-MenuEntry([string]$Group, [string]$Name, [string]$Kind, [string]$Target, [bool]$Confirm = $false, [int]$Glyph = 0, [string]$Detail = '') {
    [pscustomobject]@{ Group = $Group; Name = $Name; Kind = $Kind; Target = $Target; Confirm = $Confirm; Glyph = $Glyph; Detail = $Detail }
}

function Get-VivacMenuEntries {
    if ($null -eq $script:StartApps) { Update-VivacStartApps }
    $e = New-Object System.Collections.Generic.List[object]
    foreach ($a in $script:StartApps) { $e.Add((New-MenuEntry 'apps' $a.Name 'app' $a.AppID $false 0xE71D)) }

    # "Recommended": the most recent files Windows itself recorded.
    $recent = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
    foreach ($f in @(Get-ChildItem -LiteralPath $recent -Filter '*.lnk' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)) {
        $e.Add((New-MenuEntry 'recent' $f.BaseName 'path' $f.FullName $false 0xE8A5 $f.LastWriteTime.ToString('g')))
    }

    $folders = @(
        @('menu.folder.home', $env:USERPROFILE), @('menu.folder.desktop', [Environment]::GetFolderPath('Desktop')),
        @('menu.folder.documents', [Environment]::GetFolderPath('MyDocuments')), @('menu.folder.downloads', 'shell:Downloads'),
        @('menu.folder.pictures', [Environment]::GetFolderPath('MyPictures')), @('menu.folder.music', [Environment]::GetFolderPath('MyMusic')),
        @('menu.folder.videos', [Environment]::GetFolderPath('MyVideos')), @('menu.folder.thispc', 'shell:MyComputerFolder'),
        @('menu.folder.network', 'shell:NetworkPlacesFolder'), @('menu.folder.recycle', 'shell:RecycleBinFolder'))
    foreach ($f in $folders) {
        $detail = $f[1]
        if ($detail -like 'shell:*') { $detail = '' }
        $e.Add((New-MenuEntry 'folders' (T $f[0]) 'explore' $f[1] $false 0xE8B7 $detail))
    }

    $settingsPages = @(
        @('menu.set.home', 'ms-settings:', 0xE713), @('menu.set.system', 'ms-settings:display', 0xE7F4), @('menu.set.sound', 'ms-settings:sound', 0xE767),
        @('menu.set.network', 'ms-settings:network', 0xE701), @('menu.set.bluetooth', 'ms-settings:bluetooth', 0xE702),
        @('menu.set.personalization', 'ms-settings:personalization', 0xE771), @('menu.set.apps', 'ms-settings:appsfeatures', 0xE71D),
        @('menu.set.accounts', 'ms-settings:yourinfo', 0xE716), @('menu.set.time', 'ms-settings:dateandtime', 0xE917),
        @('menu.set.privacy', 'ms-settings:privacy', 0xE72E), @('menu.set.security', 'windowsdefender:', 0xEA18),
        @('menu.set.update', 'ms-settings:windowsupdate', 0xE895), @('menu.set.about', 'ms-settings:about', 0xE946))
    foreach ($s in $settingsPages) { $e.Add((New-MenuEntry 'settings' (T $s[0]) 'uri' $s[1] $false $s[2])) }

    # The Win+X menu.
    $tools = @(
        @('menu.tool.terminal', 'wt.exe', '', 0xE756), @('menu.tool.terminal_admin', 'wt.exe', 'admin', 0xE7EF),
        @('menu.tool.explorer', 'explorer.exe', '', 0xEC50), @('menu.tool.task_manager', 'taskmgr.exe', '', 0xE9D9),
        @('menu.tool.device_manager', 'devmgmt.msc', '', 0xE772), @('menu.tool.disk_management', 'diskmgmt.msc', '', 0xEDA2),
        @('menu.tool.computer_management', 'compmgmt.msc', '', 0xE7F8), @('menu.tool.event_viewer', 'eventvwr.msc', '', 0xE7BA),
        @('menu.tool.network_connections', 'ncpa.cpl', '', 0xE839), @('menu.tool.power_options', 'powercfg.cpl', '', 0xE83F),
        @('menu.tool.control_panel', 'control.exe', '', 0xE90F))
    foreach ($t in $tools) {
        $kind = 'run'
        if ($t[2] -eq 'admin') { $kind = 'run-admin' }
        $e.Add((New-MenuEntry 'tools' (T $t[0]) $kind $t[1] $false $t[3] $t[1]))
    }

    $e.Add((New-MenuEntry 'session' (T 'power.lock') 'power' 'lock' $false 0xE72E))
    $e.Add((New-MenuEntry 'session' (T 'menu.session.switch_user') 'power' 'switch' $false 0xE748))
    $e.Add((New-MenuEntry 'session' (T 'power.logout') 'power' 'logout' $true 0xE77B))
    $e.Add((New-MenuEntry 'session' (T 'power.sleep') 'power' 'sleep' $false 0xE708))
    $e.Add((New-MenuEntry 'session' (T 'power.restart') 'power' 'restart' $true 0xE72C))
    $e.Add((New-MenuEntry 'session' (T 'power.shutdown') 'power' 'shutdown' $true 0xE7E8))
    # What the Linux half is reachable through (docs/bridge.md): each only
    # once it is set up.
    if (Test-VivacRebootOther) { $e.Add((New-MenuEntry 'session' (T 'power.other') 'bridge' 'reboot-other' $true 0xE895)) }
    if (Get-VivacSharedRoot) {
        $e.Add((New-MenuEntry 'session' (T 'bridge.drop_in') 'bridge' 'drop-in' $false 0xE896))
        $e.Add((New-MenuEntry 'session' (T 'bridge.drop_out') 'bridge' 'drop-out' $false 0xE898))
    }
    if (Test-Path -LiteralPath (Get-VivacLinkConfPath)) { $e.Add((New-MenuEntry 'session' (T 'bridge.link_clip') 'bridge' 'link-clip' $false 0xE8C8)) }
    # Waking needs the other machine's hardware address, which a ping learns.
    if (Test-Path -LiteralPath (Get-VivacLinkPeerMacPath)) { $e.Add((New-MenuEntry 'session' (T 'bridge.link_wake') 'bridge' 'link-wake' $false 0xE7E8)) }
    # The shared mouse, once lan-mouse is installed; the row says what it is now.
    if (Find-VivacLanMouse) {
        $mouseKey = 'bridge.mouse_off'
        if ((Read-VivacMouseConf).enabled -eq 'yes') { $mouseKey = 'bridge.mouse_on' }
        $e.Add((New-MenuEntry 'session' (T $mouseKey) 'bridge' 'mouse-toggle' $false 0xE962))
    }
    # The phone, a category of its own while KDE Connect is installed
    # (lib/Phone.psm1); read from what the bar last saw, never asked here.
    foreach ($p in @(Get-VivacPhoneMenuEntries ${function:New-MenuEntry})) { $e.Add($p) }
    # Hermes, once it is installed (docs/bridge.md, "Hermes across the dual boot").
    if (Find-VivacHermes) { $e.Add((New-MenuEntry 'session' (T 'hermes.menu') 'bridge' 'hermes' $false 0xE99A)) }
    # A phone with LocalSend (docs/bridge.md, "Phones: LocalSend"): needs nothing set up to send.
    $e.Add((New-MenuEntry 'session' (T 'localsend.menu_send') 'bridge' 'localsend-send' $false 0xE8EA))
    $e.Add((New-MenuEntry 'session' (T 'localsend.menu_toggle') 'bridge' 'localsend-toggle' $false 0xE8EA))
    $e
}

# The phone's actions, each in a process of its own: the menu closes at once
# and the result comes as a notification (bin/vivac-phone.ps1).
function Invoke-PhoneAction([string]$Target) {
    $action, $id, $name = $Target -split '\|', 3
    $switch = @{ ring = '-Ring'; 'send-file' = '-SendFile'; 'send-clip' = '-SendClipboard'; manage = '-Manage' }[$action]
    if (-not $switch) { return }
    $phoneArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path (Get-VivacPaths).Repo 'bin\vivac-phone.ps1')`"", $switch)
    if ($action -ne 'manage') {
        if (-not (Test-VivacPhoneId $id)) { return }
        $phoneArgs += @('-Device', $id, '-Name', (ConvertTo-VivacArgument $name))
    }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $phoneArgs
}

# Whether "restart in Linux" is set up: its task is registered. Asked once per
# process; the Task Scheduler takes a moment to answer.
$script:RebootOther = $null
function Test-VivacRebootOther {
    if ($null -eq $script:RebootOther) {
        $script:RebootOther = [bool](Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'reboot-other' -ErrorAction SilentlyContinue)
    }
    $script:RebootOther
}

# The bridge's actions, from the menu and the power menu.
function Invoke-BridgeAction([string]$Id) {
    $bin = Join-Path (Get-VivacPaths).Repo 'bin'
    switch ($Id) {
        'reboot-other' { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-reboot-other.ps1`"") }
        { $_ -in 'drop-in', 'drop-out' } {
            $folder = Get-VivacDropFolder ($Id.Substring(5))
            if (-not $folder) { return }
            [void](New-Item -ItemType Directory -Force -Path $folder)
            Start-Process explorer.exe -ArgumentList "`"$folder`""
        }
        'link-clip' { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-link.ps1`"", 'send-clip', '-Notify') }
        'link-wake' { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-link.ps1`"", 'wake', '-Notify') }
        'mouse-toggle' { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-mouse.ps1`"", 'toggle', '-Notify') }
        # Hermes wants a console of its own: the window stays.
        'hermes' { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-hermes.ps1`"") }
        # The phone drop says what it did in a card of its own.
        { $_ -in 'localsend-send', 'localsend-toggle' } {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\vivac-localsend.ps1`"", ($Id.Substring(10) -replace '^send$', 'pick'), '-Notify')
        }
    }
}

# Matching ignores case and accents, and every word typed must appear:
# "conf red" finds "Configuracion: Red e Internet".
function ConvertTo-MenuKey([string]$s) {
    $d = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    -join @($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

# What was opened from the menu and how often, so that it comes first. Only
# applications, folders, settings pages and tools are counted: never a recent
# file's name nor anything typed.
function Get-MenuUsagePath { Join-Path (Get-VivacPaths).State 'menu-usage.tsv' }
function Read-VivacMenuUsage {
    $uses = @{}
    $path = Get-MenuUsagePath
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            $cols = $line -split "`t", 2
            if ($cols.Count -eq 2 -and $cols[0] -match '^\d+$') { $uses[$cols[1]] = [int]$cols[0] }
        }
    }
    $uses
}
function Add-VivacMenuUse($Entry) {
    if (@('app', 'explore', 'uri', 'run', 'run-admin') -notcontains $Entry.Kind) { return }
    $uses = Read-VivacMenuUsage
    $id = "$($Entry.Kind)|$($Entry.Target)"
    $uses[$id] = 1 + [int]$uses[$id]
    $text = -join @($uses.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 200 | ForEach-Object { "$($_.Value)`t$($_.Key)`n" })
    Write-VivacFile -Path (Get-MenuUsagePath) -Text $text
}

# What is typed, read as arithmetic: "2+2", "(1200*0,21)/3", "2^10".
function Get-MenuCalculation([string]$Query) {
    $q = $Query.Trim()
    if ($q -notmatch '^[\d\s\.,\+\-\*/\(\)%\^]+$' -or $q -notmatch '\d' -or $q -notmatch '[\+\-\*/%\^]') { return $null }
    $expr = $q -replace ',', '.'
    while ($expr -match '(\d+(?:\.\d+)?)\s*\^\s*(\d+(?:\.\d+)?)') {
        $expr = $expr.Replace($Matches[0], [string][Math]::Pow([double]$Matches[1], [double]$Matches[2]))
    }
    try {
        $v = (New-Object Data.DataTable).Compute($expr, '')
        if ($v -is [DBNull]) { return $null }
        $d = [double]$v
        if ([double]::IsInfinity($d) -or [double]::IsNaN($d)) { return $null }
        return $d.ToString('G15', [Globalization.CultureInfo]::CurrentCulture)
    } catch { return $null }
}

function Invoke-PowerAction([string]$Id) {
    switch ($Id) {
        'lock'     { Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation' }
        'switch'   { Start-Process tsdiscon.exe -WindowStyle Hidden }
        'logout'   { Start-Process shutdown.exe -ArgumentList '/l' -WindowStyle Hidden }
        'sleep'    { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) }
        'restart'  { Start-Process shutdown.exe -ArgumentList '/r', '/t', '0' -WindowStyle Hidden }
        'shutdown' { Start-Process shutdown.exe -ArgumentList '/s', '/t', '0' -WindowStyle Hidden }
    }
}

# Admin is Ctrl+Enter: for programs, tools and files; an application of the
# Start menu or a page opens as usual.
function Invoke-MenuEntry($Entry, [string]$Query, [switch]$Admin) {
    switch ($Entry.Kind) {
        'app'       { Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($Entry.Target)" }
        'path'      { if ($Admin) { Start-Process -FilePath $Entry.Target -Verb RunAs } else { Start-Process -FilePath $Entry.Target } }
        'explore'   { Start-Process explorer.exe -ArgumentList "`"$($Entry.Target)`"" }
        'uri'       { Start-Process $Entry.Target }
        'run'       {
            if ($Entry.Target -like 'shell:*') { Start-Process explorer.exe -ArgumentList $Entry.Target }
            elseif ($Admin) { Start-Process $Entry.Target -Verb RunAs }
            else { Start-Process $Entry.Target }
        }
        'run-admin' { Start-Process $Entry.Target -Verb RunAs }
        'power'     { Invoke-PowerAction $Entry.Target }
        'bridge'    { Invoke-BridgeAction $Entry.Target }
        'phone'     { Invoke-PhoneAction $Entry.Target }
        'copy'      { Set-Clipboard -Value $Entry.Target }
        'find-files' {
            $q = [Uri]::EscapeDataString($Query)
            Start-Process explorer.exe -ArgumentList "`"search-ms:query=$q&crumb=location:$([Uri]::EscapeDataString($env:USERPROFILE))`""
        }
        'find-web'  { Start-Process ('https://www.bing.com/search?q=' + [Uri]::EscapeDataString($Query)) }
        # What Windows' Run dialog does: a program on the PATH or in App Paths,
        # with arguments, a folder, a document, a URL, %VARIABLES% -- all
        # through the shell's own 'start'.
        'run-text'  {
            if ($Admin) { Start-Process cmd.exe -ArgumentList ('/d /c start "" ' + $Query) -WindowStyle Hidden -Verb RunAs }
            else { Start-Process cmd.exe -ArgumentList ('/d /c start "" ' + $Query) -WindowStyle Hidden }
        }
    }
}

function Get-MenuXaml($p) {
    $t = Get-PanelTokens $p
    $up = "$([char]0x2191)$([char]0x2193)"; $ret = [string][char]0x21B5
    $hints = "<Border DockPanel.Dock=`"Bottom`" Margin=`"0,10,0,0`" Padding=`"2,8,0,0`" BorderBrush=`"#$($t.line)`" BorderThickness=`"0,1,0,0`">$(Get-KitHintsXamlV2 $t @(@($up, (T 'menu.key.move')), @('Tab', (T 'menu.key.category')), @($ret, (T 'menu.key.open')), @("Ctrl+$ret", (T 'menu.key.admin')), @('Esc', (T 'menu.key.close'))))</Border>"
    $icon = $script:KitIconFont
    $frequent = ConvertTo-XmlText (T 'menu.section.frequent').ToUpper()
    $body = @"
<Grid>
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="230"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <Border Grid.Column="0" Background="#$($t.surface)" CornerRadius="12,0,0,12" Padding="12,16">
  <DockPanel>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,0,0,14">
      <Border Width="36" Height="36" CornerRadius="18" Background="#$($t.accent)">
        <TextBlock x:Name="Initial" FontSize="15" FontWeight="Bold" Foreground="#$($t.actionText)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="User" FontSize="13" FontWeight="Bold" Foreground="#$($t.text)"/>
        <TextBlock x:Name="Today" FontSize="11" Foreground="#$($t.textSecondary)"/>
      </StackPanel>
    </StackPanel>
    <Grid x:Name="Power" DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
    </Grid>
    <ListBox x:Name="Cats" Background="Transparent" BorderThickness="0" Focusable="False"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemContainerStyle>
        <Style TargetType="ListBoxItem">
          <Setter Property="Foreground" Value="#$($t.textSecondary)"/>
          <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
          <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" CornerRadius="8" Margin="0,1" Padding="9,0,12,0" Background="Transparent" BorderThickness="3,0,0,0" BorderBrush="Transparent">
              <ContentPresenter x:Name="Pres"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#66$($t.surfaceAlt)"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#$($t.surfaceAlt)"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#$($t.accent)"/>
                <Setter TargetName="Pres" Property="TextElement.Foreground" Value="#$($t.text)"/>
                <Setter TargetName="Pres" Property="TextElement.FontWeight" Value="Bold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Style>
      </ListBox.ItemContainerStyle>
      <ListBox.ItemTemplate><DataTemplate>
        <Grid Height="36">
          <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="{Binding Glyph}" FontFamily="$icon" FontSize="15" Foreground="#$($t.accent)" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="1" Text="{Binding Name}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          <TextBlock Grid.Column="2" Text="{Binding Sub}" FontSize="11" FontWeight="Normal" Foreground="#$($t.muted)" VerticalAlignment="Center" Margin="6,0,0,0"/>
        </Grid>
      </DataTemplate></ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
  </Border>

  <DockPanel Grid.Column="1" Margin="16">
    <Border DockPanel.Dock="Top" Background="#$($t.surface)" CornerRadius="12" Padding="14,0" Height="42" Margin="0,0,0,12"
            BorderBrush="#$($t.accent)" BorderThickness="2">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid Margin="0,0,10,0" VerticalAlignment="Center">$(Get-PanelIconXaml 'search' 17 $t.accent)</Grid>
        <TextBlock x:Name="Placeholder" Grid.Column="1" FontSize="13" Foreground="#$($t.textSecondary)" VerticalAlignment="Center" IsHitTestVisible="False"
                   Text="$(ConvertTo-XmlText (T 'menu.placeholder'))"/>
        <TextBox x:Name="Filter" Grid.Column="1" FontSize="13" Background="Transparent" BorderThickness="0" Padding="0"
                 Foreground="#$($t.text)" CaretBrush="#$($t.accent)" VerticalAlignment="Center"/>
        <TextBlock x:Name="Count" Grid.Column="2" FontSize="12" Foreground="#$($t.textSecondary)" VerticalAlignment="Center" Margin="12,0,0,0"/>
      </Grid>
    </Border>
    $hints
    <ListBox x:Name="Rows" Background="Transparent" BorderThickness="0" Focusable="False"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True"
             VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.IsVirtualizingWhenGrouping="True"
             VirtualizingPanel.VirtualizationMode="Recycling" VirtualizingPanel.ScrollUnit="Pixel">
      <ListBox.ItemContainerStyle>
        <Style TargetType="ListBoxItem">
          <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
          <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" CornerRadius="10" Margin="0,2,6,2" Background="#$($t.surface)">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t.surfaceAlt)"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#$($t.actionFill)"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Style>
      </ListBox.ItemContainerStyle>
      <ListBox.GroupStyle>
        <GroupStyle>
          <GroupStyle.HeaderTemplate><DataTemplate>
            <DockPanel Margin="2,8,6,4" Height="20">
              <TextBlock x:Name="Note" DockPanel.Dock="Right" Text="$(ConvertTo-XmlText (T 'menu.sorted_by_use'))" FontSize="12" Foreground="#$($t.textSecondary)" VerticalAlignment="Center" Visibility="Collapsed"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="Bold" Foreground="#$($t.muted)" VerticalAlignment="Center"/>
                <Border Background="#$($t.surface)" CornerRadius="8" Padding="7,1" Margin="8,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="{Binding ItemCount}" FontSize="12" Foreground="#$($t.text)"/>
                </Border>
              </StackPanel>
            </DockPanel>
            <DataTemplate.Triggers>
              <DataTrigger Binding="{Binding Name}" Value="$frequent"><Setter TargetName="Note" Property="Visibility" Value="Visible"/></DataTrigger>
            </DataTemplate.Triggers>
          </DataTemplate></GroupStyle.HeaderTemplate>
        </GroupStyle>
      </ListBox.GroupStyle>
      <ListBox.ItemTemplate><DataTemplate>
        <Border x:Name="Fill" CornerRadius="10" Padding="10,7">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border x:Name="Tile" Width="34" Height="34" CornerRadius="8" Background="#$($t.surfaceAlt)">
              <Grid>
                <TextBlock x:Name="G" Text="{Binding Glyph}" FontFamily="$icon" FontSize="17" Foreground="#$($t.accent)"
                           HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="{Binding ShowGlyph, Converter={StaticResource B2V}}"/>
                <Image Source="{Binding Icon}" Width="24" Height="24" RenderOptions.BitmapScalingMode="HighQuality"/>
              </Grid>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="12,0,8,0">
              <TextBlock x:Name="N" Text="{Binding Name}" FontSize="13" FontWeight="Bold" TextTrimming="CharacterEllipsis" Foreground="#$($t.text)"/>
              <TextBlock x:Name="S" Text="{Binding Sub}" FontSize="12" TextTrimming="CharacterEllipsis" Foreground="#$($t.textSecondary)"/>
            </StackPanel>
            <StackPanel x:Name="Go" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
              <Border Background="#$($t.surface)" BorderBrush="#$($t.line)" BorderThickness="1" CornerRadius="6" Padding="6,1">
                <TextBlock Text="&#x21B5;" FontSize="12" Foreground="#$($t.text)"/>
              </Border>
              <TextBlock x:Name="GoText" Text="$(ConvertTo-XmlText (T 'menu.key.open'))" FontSize="11" Margin="6,0,0,0" Foreground="#$($t.actionText)" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </Border>
        <DataTemplate.Triggers>
          <DataTrigger Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="True">
            <Setter TargetName="Go" Property="Visibility" Value="Visible"/>
            <Setter TargetName="Tile" Property="Background" Value="#$($t.bg)"/>
            <Setter TargetName="N" Property="Foreground" Value="#$($t.actionText)"/>
            <Setter TargetName="S" Property="Foreground" Value="#$($t.actionText)"/>
            <Setter TargetName="S" Property="Opacity" Value="0.85"/>
          </DataTrigger>
          <DataTrigger Binding="{Binding Urgent}" Value="True">
            <Setter TargetName="Fill" Property="Background" Value="#$($t.alert)"/>
            <Setter TargetName="N" Property="Foreground" Value="#$($t.bg)"/>
            <Setter TargetName="S" Property="Foreground" Value="#$($t.bg)"/>
            <Setter TargetName="Tile" Property="Background" Value="#$($t.bg)"/>
            <Setter TargetName="GoText" Property="Foreground" Value="#$($t.bg)"/>
          </DataTrigger>
        </DataTemplate.Triggers>
      </DataTemplate></ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Grid>
"@
    $body
}

function Show-Menu([switch]$NoShow, [hashtable]$Registry, [string]$Category = '') {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'menu' }
    Import-VivacMenu
    $surfaceName = 'menu'
    $p = Get-Palette
    $glyph = { param([int]$code) [string][char]$code }
    $entries = @(Get-VivacMenuEntries)
    $uses = Read-VivacMenuUsage
    $groupOrder = @('apps', 'recent', 'folders', 'settings', 'tools', 'session')
    # The phone's category exists only while KDE Connect is installed.
    if (@($entries | Where-Object { $_.Group -eq 'phone' }).Count) { $groupOrder += 'phone' }
    $groupGlyph = @{ all = 0xE80F; apps = 0xE71D; recent = 0xE823; folders = 0xE8B7; settings = 0xE713; tools = 0xE90F; session = 0xE7E8; phone = 0xE8EA }
    $sectionLabel = @{}
    foreach ($g in @('all') + $groupOrder) { $sectionLabel[$g] = T "menu.section.$g" }

    # One row per entry, built once; the list shows a filtered selection.
    $all = New-Object 'System.Collections.Generic.List[VivacMenuRow]'
    foreach ($x in $entries) {
        $r = New-Object VivacMenuRow
        $r.Name = $x.Name
        $sub = $x.Detail
        if (-not $sub) { $sub = T "menu.group.$($x.Group)" }
        $r.Sub = $sub
        $r.Glyph = & $glyph $x.Glyph
        $r.Group = $x.Group
        $r.Section = $sectionLabel[$x.Group].ToUpper()
        $r.Key = ConvertTo-MenuKey "$($x.Name) $(T "menu.group.$($x.Group)") $($sectionLabel[$x.Group])"
        $r.NameKey = ConvertTo-MenuKey $x.Name
        $r.Uses = [double][int]$uses["$($x.Kind)|$($x.Target)"]
        $r.Entry = $x
        switch ($x.Kind) {
            'app'     { $r.IconKey = "shell:AppsFolder\$($x.Target)" }
            'path'    { $r.IconKey = $x.Target }
            'explore' { $r.IconKey = $x.Target }
        }
        $all.Add($r)
    }

    $window = New-VivacWindow (Get-PanelWindowXaml $p 'vivac - menu' 1000 640 (Get-MenuXaml $p) 0 (Get-KitResourcesXaml $p))
    $rows = $window.FindName('Rows')
    $cats = $window.FindName('Cats')
    $filter = $window.FindName('Filter')
    $placeholder = $window.FindName('Placeholder')
    $count = $window.FindName('Count')
    $state = @{ Armed = $null; Rendering = $false }

    $name = [Environment]::UserName
    try { $full = ([ADSI]"WinNT://$env:COMPUTERNAME/$name,user").FullName; if ($full) { $name = [string]$full } } catch { }
    $window.FindName('User').Text = $name
    $window.FindName('Initial').Text = $name.Substring(0, 1).ToUpper()
    $culture = [Globalization.CultureInfo]::GetCultureInfo($settings['language'])
    $today = (Get-Date).ToString('dddd, d MMMM', $culture)
    $window.FindName('Today').Text = $today.Substring(0, 1).ToUpper() + $today.Substring(1)

    # The categories: everything, then one per group, each with how many of
    # its rows match what is typed.
    $catRows = New-Object 'System.Collections.Generic.List[VivacMenuRow]'
    foreach ($g in @('all') + $groupOrder) {
        $c = New-Object VivacMenuRow
        $c.Name = $sectionLabel[$g]; $c.Glyph = & $glyph $groupGlyph[$g]; $c.Group = $g
        $catRows.Add($c)
    }
    $cats.ItemsSource = $catRows
    $cats.SelectedIndex = 0
    # Opened on one category (the bar's phone opens the Phone one).
    for ($i = 0; $i -lt $catRows.Count; $i++) { if ($catRows[$i].Group -eq $Category) { $cats.SelectedIndex = $i } }

    $newAction = {
        param([string]$Kind, [string]$Label, [int]$Code, [string]$Target = '')
        $r = New-Object VivacMenuRow
        $r.Name = $Label; $r.Glyph = & $glyph $Code; $r.Group = 'actions'
        $r.Section = (T 'menu.section.actions').ToUpper()
        $r.Entry = New-MenuEntry 'tools' $Label $Kind $Target
        $r.Sub = T "menu.action.$Kind"
        $r
    }

    $setCounts = {
        param($source)
        $n = @{ all = 0 }
        foreach ($r in $source) { $n[$r.Group] = 1 + [int]$n[$r.Group]; $n['all']++ }
        foreach ($c in $catRows) { $c.Sub = [string][int]$n[$c.Group] }
    }

    $render = {
        if ($state.Rendering) { return }
        $state.Rendering = $true
        try {
            $state.Armed = $null
            foreach ($r in $all) { if ($r.Urgent) { $r.Urgent = $false; $r.Name = $r.Entry.Name } }
            $query = $filter.Text.Trim()
            $placeholder.Visibility = if ($filter.Text) { 'Collapsed' } else { 'Visible' }
            $words = [string[]]@((ConvertTo-MenuKey $query) -split '\s+' | Where-Object { $_ })
            $cat = 'all'
            if ($cats.SelectedItem) { $cat = $cats.SelectedItem.Group }
            $list = New-Object 'System.Collections.Generic.List[VivacMenuRow]'

            if ($words.Count) {
                $matched = [VivacMenuRank]::Filter($all, $words)
                & $setCounts $matched
                $calc = Get-MenuCalculation $query
                if ($null -ne $calc) { $list.Add((& $newAction 'copy' "= $calc" 0xE8EF $calc)) }
                foreach ($r in $matched) { if ($cat -eq 'all' -or $r.Group -eq $cat) { $list.Add($r) } }
                $list.Add((& $newAction 'run-text' (T 'menu.run' @($query)) 0xE768))
                $list.Add((& $newAction 'find-files' (T 'menu.find_files' @($query)) 0xE721))
                $list.Add((& $newAction 'find-web' (T 'menu.find_web' @($query)) 0xE774))
            } else {
                & $setCounts $all
                if ($cat -eq 'all') {
                    # What is used most, first, as rofi keeps its history.
                    $frequent = (T 'menu.section.frequent').ToUpper()
                    foreach ($r in @($all | Where-Object { $_.Uses -gt 0 } | Sort-Object Uses -Descending | Select-Object -First 8)) {
                        $list.Add($r.InSection($frequent))
                    }
                }
                foreach ($r in $all) { if ($cat -eq 'all' -or $r.Group -eq $cat) { $list.Add($r) } }
            }

            $view = [Windows.Data.ListCollectionView]::new($list)
            $view.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Section'))
            $rows.ItemsSource = $view
            $count.Text = T 'menu.count' @([string]@($list | Where-Object { $_.Group -ne 'actions' }).Count)
            if ($rows.Items.Count) { $rows.SelectedIndex = 0; $rows.ScrollIntoView($rows.Items[0]) }
        } finally { $state.Rendering = $false }
    }

    # Ending the session asks first, as the power menu does: the first Enter
    # arms the row, the second carries it out.
    $act = {
        param([bool]$Admin = $false)
        $sel = $rows.SelectedItem
        if (-not $sel) { return }
        $entry = $sel.Entry
        if ($entry.Confirm -and -not [object]::ReferenceEquals($state.Armed, $sel)) {
            $state.Armed = $sel
            $sel.Name = "$($entry.Name)  -  $(T 'power.confirm')"
            $sel.Urgent = $true
            return
        }
        $query = $filter.Text.Trim()
        $window.Close()
        try { Add-VivacMenuUse $entry } catch { }
        try { Invoke-MenuEntry $entry $query -Admin:$Admin } catch { }
    }

    # The power buttons under the categories: one click for lock and sleep,
    # two for restart and shut down, the second within the same opening.
    $powerGrid = $window.FindName('Power')
    $col = 0
    foreach ($id in 'lock', 'sleep', 'restart', 'shutdown') {
        $entry = $entries | Where-Object { $_.Kind -eq 'power' -and $_.Target -eq $id } | Select-Object -First 1
        $b = New-Object Windows.Controls.Border
        $b.Height = 38; $b.Margin = '3,0'; $b.CornerRadius = 10; $b.Cursor = 'Hand'
        $b.Background = 'Transparent'
        $b.ToolTip = $entry.Name
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = & $glyph $entry.Glyph
        $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $t.FontSize = 15
        $t.Foreground = "#$($p['COLOR_FG'])"
        $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
        $b.Child = $t
        $b.Tag = @{ Entry = $entry; Armed = $false; Text = $t }
        [Windows.Controls.Grid]::SetColumn($b, $col++)
        $b.Add_MouseEnter({ param($s) $s.Background = "#$($p['COLOR_SURFACE_ALT'])" })
        $b.Add_MouseLeave({ param($s) $s.Background = 'Transparent' })
        $b.Add_MouseLeftButtonUp({
                param($s)
                $tag = $s.Tag
                if ($tag.Entry.Confirm -and -not $tag.Armed) {
                    $tag.Armed = $true
                    $tag.Text.Foreground = "#$($p['COLOR_URGENT'])"
                    $s.ToolTip = "$($tag.Entry.Name)  -  $(T 'power.confirm')"
                    return
                }
                $window.Close()
                try { Invoke-MenuEntry $tag.Entry '' } catch { }
            })
        [void]$powerGrid.Children.Add($b)
    }

    $move = {
        param([int]$To)
        if (-not $rows.Items.Count) { return }
        $rows.SelectedIndex = [Math]::Max(0, [Math]::Min($rows.Items.Count - 1, $To))
        $rows.ScrollIntoView($rows.SelectedItem)
    }
    $filter.Add_TextChanged({ & $render })
    $cats.Add_SelectionChanged({ & $render; [void]$filter.Focus() })
    $window.Add_PreviewKeyDown({
            param($s, $e)
            $k = [string]$e.Key
            $ctrl = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0
            $shift = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0
            # Esc first empties the box, then closes.
            if ($k -eq 'Escape') { if ($filter.Text) { $filter.Text = '' } else { $window.Close() }; $e.Handled = $true; return }
            if ($k -eq 'Down') { & $move ($rows.SelectedIndex + 1); $e.Handled = $true; return }
            if ($k -eq 'Up') { & $move ($rows.SelectedIndex - 1); $e.Handled = $true; return }
            if ($k -eq 'PageDown') { & $move ($rows.SelectedIndex + 8); $e.Handled = $true; return }
            if ($k -eq 'PageUp') { & $move ($rows.SelectedIndex - 8); $e.Handled = $true; return }
            if ($ctrl -and $k -eq 'Home') { & $move 0; $e.Handled = $true; return }
            if ($ctrl -and $k -eq 'End') { & $move ($rows.Items.Count - 1); $e.Handled = $true; return }
            if ($k -eq 'Tab') {
                $n = $catRows.Count
                $step = 1
                if ($shift) { $step = -1 }
                $cats.SelectedIndex = ($cats.SelectedIndex + $step + $n) % $n
                $e.Handled = $true; return
            }
            if ($ctrl -and $k -match '^D([1-8])$' -and [int]$Matches[1] -le $catRows.Count) { $cats.SelectedIndex = [int]$Matches[1] - 1; $e.Handled = $true; return }
            if ($k -eq 'Return') { & $act $ctrl; $e.Handled = $true; return }
        })
    # One click opens, as in a launcher; the scroll bar is not a row.
    $rows.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $item = [Windows.Controls.ItemsControl]::ContainerFromElement($rows, $e.OriginalSource)
            if ($item -is [Windows.Controls.ListBoxItem]) { $rows.SelectedItem = $item.DataContext; & $act $false }
        })
    $window.Add_ContentRendered({ [void]$filter.Focus() })
    & $render
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# ---------------------------------------------------------------- sound panel

# The sound panel the bar's volume gauge opens, as pavucontrol is in the
# source: the playback and recording devices (click one to make it the
# default), each with its volume and mute, and the mixer of the applications
# playing. Core Audio is reached through lib/VivacAudio.cs.
function Import-VivacAudio {
    if ('VivacAudio' -as [type]) { return }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacAudio.cs'))) -Language CSharp
}

# "Loading..." with a turning ring (lib/VivacLoading.cs), for the moment
# between a key and the surface it opens: shown only if the surface is not on
# screen within a moment, gone as soon as it is.
function Import-VivacLoading {
    if (-not ('VivacLoading' -as [type])) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $refs = @([Windows.Window].Assembly.Location, [Windows.Media.Brush].Assembly.Location,
            [Windows.Threading.Dispatcher].Assembly.Location, [Windows.Markup.XamlReader].Assembly.Location,
            [System.Xaml.XamlType].Assembly.Location)
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacLoading.cs'))) -ReferencedAssemblies $refs -Language CSharp
    }
    $p = Get-Palette
    [VivacLoading]::Init($p['COLOR_BG'], $p['COLOR_FG'], $p['COLOR_ACCENT'], (T 'surface.loading'))
}
function Start-VivacLoading {
    try {
        Import-VivacLoading
        [VivacLoading]::Show()
    } catch { }
}

function Get-SliderStyleXaml($p) {
    @"
<Style TargetType="Slider">
  <Setter Property="IsMoveToPointEnabled" Value="True"/>
  <Setter Property="Minimum" Value="0"/>
  <Setter Property="Maximum" Value="100"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Slider">
        <Grid Background="Transparent" Height="18">
          <Border Height="6" CornerRadius="3" Background="#$($p['COLOR_SURFACE'])" VerticalAlignment="Center"/>
          <Track x:Name="PART_Track">
            <Track.DecreaseRepeatButton>
              <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="6" CornerRadius="3" Background="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template>
              </RepeatButton>
            </Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton>
              <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template>
              </RepeatButton>
            </Track.IncreaseRepeatButton>
            <Track.Thumb>
              <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Width="14" Height="14" Fill="#$($p['COLOR_FG'])"/></ControlTemplate></Thumb.Template></Thumb>
            </Track.Thumb>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
}

# What the panel draws from: the playback and recording devices and the
# applications playing, as plain objects, grouped as the panel shows them. A
# machine with no audio endpoint (a virtual machine) answers with nothing
# instead of an error; tests and screenshots replace this function to feed
# sample data.
function Get-VivacSoundData {
    $data = @{ Outputs = @(); Inputs = @(); Apps = @() }
    try { $data.Outputs = @([VivacAudio]::Devices(0)) } catch { }
    try { $data.Inputs = @([VivacAudio]::Devices(1)) } catch { }
    try { $data.Apps = @(Group-SoundSessions @([VivacAudio]::Sessions((T 'sound.system_sounds')))) } catch { }
    $data
}

# The sound panel, as designed for both systems (see linux/lib/vivacpanel/
# sound.py): the default output's level up top with the outputs as chips,
# one card per application with its own level and mute, the inputs below.
# Windows' scalar tops out at 100, so the faders do too and carry no tinted
# zone past it; everything else is the Linux panel's.
function Show-Sound([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'sound' }
    $surfaceName = 'sound'
    Import-VivacAudio
    try { Import-VivacMenu } catch { }
    $p = Get-Palette
    $t = Get-KitTokens $p
    $cap = 100
    $hints = @(@((T 'sound.key.click'), (T 'sound.key.default')), @((T 'sound.key.icon'), (T 'sound.key.mute')), @('Esc', (T 'sound.key.close')))
    $body = @'
<ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
  <StackPanel x:Name="Sections" Margin="0,0,0,2"/>
</ScrollViewer>
'@
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - sound' 440 (Get-KitPanelXamlV2 $t ([string][char]0xE767) (T 'sound.title') $body $hints))
    Add-KitDrawResources $window $p $cap
    Set-KitDropDown $window
    $sections = $window.FindName('Sections')
    $subtitle = $window.FindName('Subtitle')
    # The list scrolls; the window stops short of the screen's bottom.
    $window.FindName('Scroll').MaxHeight = [Math]::Max(300, $window.MaxHeight - 150)

    $more = New-Object Windows.Controls.Button
    $more.Style = $window.FindResource('KitChip')
    $more.Content = New-KitText (T 'sound.settings') $t['textSecondary'] 12
    $more.Background = New-KitBrush $t['surface']
    $more.ToolTip = T 'sound.more'
    $more.Add_Click({ $window.Close(); Start-Process 'ms-settings:sound' })
    [void]$window.FindName('HeaderRight').Children.Add($more)

    # What handlers share. Dragging holds a redraw back so a fader is not
    # rebuilt under the pointer; InputsOpen keeps the fold as the user left it.
    $state = @{ Dragging = $false; Signature = ''; InputsOpen = $false }

    $micGlyph = { param([bool]$Muted) if ($Muted) { 0xF781 } else { 0xE720 } }
    $outGlyph = { param([bool]$Muted) if ($Muted) { 0xE74F } else { 0xE767 } }
    $appGlyph = { param([bool]$Muted) if ($Muted) { 0xE74F } else { 0xE8D6 } }

    $newLabel = {
        param([string]$Text, [string]$Color, [double]$Size = 13, [bool]$Bold = $false)
        $x = New-KitText $Text $Color $Size
        if ($Bold) { $x.FontWeight = 'Bold' }
        $x.TextTrimming = 'CharacterEllipsis'
        $x
    }

    # A mute button: the glyph for the state, alert-filled while muted. It flips
    # the state, tells $OnMute (ctx, muted) and redraws. What a handler needs
    # travels in the control's Tag: the handler runs long after this block has
    # returned and its variables are gone.
    $newMute = {
        param([bool]$Muted, [scriptblock]$GlyphFor, [scriptblock]$OnMute, $Ctx, [bool]$Big = $false)
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource($(if ($Muted) { 'KitMuteOn' } else { 'KitMute' }))
        $b.Content = [string][char](& $GlyphFor $Muted)
        $b.VerticalAlignment = 'Center'
        $b.ToolTip = T 'sound.key.mute'
        if ($Big) { $b.Width = 40; $b.Height = 40; $b.FontSize = 20 }
        $b.Tag = @{ Muted = $Muted; OnMute = $OnMute; Ctx = $Ctx; State = $state }
        $b.Add_Click({
                param($s)
                & $s.Tag.OnMute $s.Tag.Ctx (-not $s.Tag.Muted)
                & $s.Tag.State.Render
            })
        $b
    }

    $newFader = {
        param([int]$Value, [bool]$Muted, [scriptblock]$OnLevel, $Ctx)
        $f = New-KitFader $window $t $Value $cap $Muted
        $f.Tag = @{ OnLevel = $OnLevel; Ctx = $Ctx; State = $state }
        $f.Add_ValueChanged({
                param($s)
                & $s.Tag.OnLevel $s.Tag.Ctx ([int][Math]::Round($s.Value))
            })
        # Held back from redraws while the knob is down.
        $f.Add_PreviewMouseLeftButtonDown({ param($s) $s.Tag.State.Dragging = $true })
        $f.Add_PreviewMouseLeftButtonUp({ param($s) $s.Tag.State.Dragging = $false })
        $f.Add_LostMouseCapture({ param($s) $s.Tag.State.Dragging = $false })
        $f
    }

    $section = {
        param([string]$Title, [int]$Count, [string]$Side, [string]$CountBg)
        $g = New-Object Windows.Controls.Grid
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $cap1 = & $newLabel $Title.ToUpper() $t['muted'] 12 $true
        $cap1.FontWeight = 'Bold'
        $n = New-Object Windows.Controls.Border
        $n.CornerRadius = 8; $n.Padding = '7,0'; $n.Margin = '8,0,0,0'
        $n.Background = New-KitBrush $CountBg
        $n.Child = New-KitText "$Count" $t['text'] 12
        [Windows.Controls.Grid]::SetColumn($n, 1)
        [void]$g.Children.Add($cap1); [void]$g.Children.Add($n)
        if ($Side) {
            $s = New-KitText $Side $t['textSecondary'] 12
            [Windows.Controls.Grid]::SetColumn($s, 3)
            [void]$g.Children.Add($s)
        }
        $g
    }

    $newCard = {
        param([string]$Bg, [double]$Radius = 12, $Padding = '14')
        $c = New-Object Windows.Controls.Border
        $c.CornerRadius = $Radius
        $c.Padding = $Padding
        $c.Background = New-KitBrush $Bg
        $c
    }

    $bigLevel = {
        param([int]$Level, [bool]$Muted)
        $b = New-Object Windows.Controls.TextBlock
        $b.FontSize = 36; $b.FontWeight = 'Bold'
        $b.Foreground = New-KitBrush $(if ($Muted) { $t['muted'] } else { $t['text'] })
        $r1 = New-Object Windows.Documents.Run "$Level"
        $r2 = New-Object Windows.Documents.Run '%'
        $r2.FontSize = 18; $r2.FontWeight = 'Normal'; $r2.Foreground = New-KitBrush $t['textSecondary']
        [void]$b.Inlines.Add($r1); [void]$b.Inlines.Add($r2)
        $b.VerticalAlignment = 'Center'
        $b
    }

    $outputCard = {
        param($outs)
        $card = & $newCard $t['surface']
        $stack = New-Object Windows.Controls.StackPanel
        $card.Child = $stack
        $head = & $section (T 'sound.output') $outs.Count (T 'sound.default') $t['bg']
        $head.Margin = '0,0,0,10'
        [void]$stack.Children.Add($head)
        if (-not $outs.Count) {
            [void]$stack.Children.Add((New-KitText (T 'sound.none') $t['textSecondary'] 12))
            return $card
        }
        $wrap = New-Object Windows.Controls.WrapPanel
        $wrap.Margin = '4,4,0,0'
        foreach ($d in $outs) {
            $name = Get-SoundShortName $d.Name
            $value = ''
            if (-not $d.IsDefault) { $value = if ($d.Muted) { T 'sound.muted_short' } else { "$($d.Volume)%" } }
            $check = ''
            if ($d.IsDefault) { $check = [string][char]0x2713 }
            $chip = New-KitChip $window $t $name $value -Selected:$d.IsDefault -Check $check
            $chip.Margin = '0,0,6,6'
            $chip.ToolTip = $d.Name
            $chip.Tag['Id'] = $d.Id
            $chip.Tag['State'] = $state
            $chip.Add_Click({ param($s) try { [VivacAudio]::SetDefault([string]$s.Tag['Id']) } catch { }; & $s.Tag['State'].Render })
            [void]$wrap.Children.Add($chip)
        }
        [void]$stack.Children.Add($wrap)
        $default = @($outs | Where-Object { $_.IsDefault })[0]
        if ($default) {
            $top = New-Object Windows.Controls.Grid
            $top.Margin = '0,2,0,10'
            foreach ($w in 'Auto', '*', 'Auto') { $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = $w })) }
            $ctx = @{ Id = $default.Id; Big = $null }
            $mute = & $newMute $default.Muted $outGlyph { param($c, $m) try { [VivacAudio]::SetMute($c.Id, $m) } catch { } } $ctx $true
            [void]$top.Children.Add($mute)
            $big = & $bigLevel $default.Volume $default.Muted
            $big.Margin = '12,0,0,0'
            $ctx.Big = $big
            [Windows.Controls.Grid]::SetColumn($big, 1)
            [void]$top.Children.Add($big)
            $tag = New-Object Windows.Controls.Border
            $tag.CornerRadius = 8; $tag.Padding = '8,2'; $tag.Background = New-KitBrush $t['bg']; $tag.VerticalAlignment = 'Center'
            $tag.Child = New-KitText (T 'sound.cap' @([string]$cap)) $t['textSecondary'] 12
            [Windows.Controls.Grid]::SetColumn($tag, 2)
            [void]$top.Children.Add($tag)
            [void]$stack.Children.Add($top)
            $fader = & $newFader $default.Volume $default.Muted { param($c, $l) try { [VivacAudio]::SetVolume($c.Id, $l) } catch { }; $c.Big.Inlines.FirstInline.Text = "$l" } $ctx
            [void]$stack.Children.Add($fader)
            [void]$stack.Children.Add((New-KitRuler $t (Get-SoundRulerValues $cap)))
        }
        $card
    }

    $appCard = {
        param($a)
        $card = & $newCard $t['surface'] 12 '12,10,12,8'
        $card.Margin = '0,0,0,6'
        $stack = New-Object Windows.Controls.StackPanel
        $card.Child = $stack
        $top = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto', 'Auto') { $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = $w })) }
        $kind = Get-SoundAppState $a
        # The program's own icon, in a tile that wears a success ring (a gap of the
        # panel's colour, then the ring) while the application plays.
        $slot = New-Object Windows.Controls.Grid
        $slot.Width = 36; $slot.Height = 36; $slot.VerticalAlignment = 'Center'; $slot.Margin = '4,0,12,0'
        if ($kind -eq 'playing') {
            $outer = New-Object Windows.Controls.Border
            $outer.Margin = '-4'; $outer.CornerRadius = 14; $outer.BorderThickness = '2'; $outer.BorderBrush = New-KitBrush $t['success']
            $gap = New-Object Windows.Controls.Border
            $gap.Margin = '-2'; $gap.CornerRadius = 12; $gap.BorderThickness = '2'; $gap.BorderBrush = New-KitBrush $t['bg']
            [void]$slot.Children.Add($outer); [void]$slot.Children.Add($gap)
        }
        $tile = New-Object Windows.Controls.Border
        $tile.CornerRadius = 10; $tile.Background = New-KitBrush $t['surfaceAlt']
        $glyph = New-KitGlyph 0xE8D6 $(if ($kind -eq 'playing') { $t['accent'] } else { $t['muted'] }) 18
        $glyph.HorizontalAlignment = 'Center'
        $exe = $null
        if ($a.ProcessId) { try { $exe = (Get-Process -Id ([int]$a.ProcessId) -ErrorAction Stop).Path } catch { } }
        if ($a.Name -eq (T 'sound.system_sounds')) { $glyph.Text = [string][char]0xEA8F }
        $tileInner = New-Object Windows.Controls.Grid
        [void]$tileInner.Children.Add($glyph)
        if ($exe -and ('VivacMenuRow' -as [type])) {
            # The program's own icon arrives on the icon thread (lib/VivacMenu.cs);
            # the glyph stands in until it does.
            $iconRow = New-Object VivacMenuRow
            $iconRow.IconKey = $exe
            $vis = New-Object Windows.Data.Binding 'ShowGlyph'
            $vis.Source = $iconRow
            $vis.Converter = New-Object Windows.Controls.BooleanToVisibilityConverter
            [void]$glyph.SetBinding([Windows.UIElement]::VisibilityProperty, $vis)
            $img = New-Object Windows.Controls.Image
            $img.Width = 22; $img.Height = 22
            [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
            $src = New-Object Windows.Data.Binding 'Icon'
            $src.Source = $iconRow
            [void]$img.SetBinding([Windows.Controls.Image]::SourceProperty, $src)
            [void]$tileInner.Children.Add($img)
        }
        $tile.Child = $tileInner
        [void]$slot.Children.Add($tile)
        [void]$top.Children.Add($slot)
        $col = New-Object Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Center'
        $nameText = & $newLabel $a.Name $(if ($a.Muted) { $t['textSecondary'] } else { $t['text'] }) 13 $true
        [void]$col.Children.Add($nameText)
        $line = New-Object Windows.Controls.StackPanel
        $line.Orientation = 'Horizontal'
        $stateColor = switch ($kind) { 'silenced' { $t['alert'] } 'playing' { $t['success'] } default { $t['textSecondary'] } }
        if ($kind -eq 'silenced') {
            $mi = New-KitGlyph 0xE74F $stateColor 12
            $mi.Margin = '0,0,6,0'
            [void]$line.Children.Add($mi)
            [void]$line.Children.Add((New-KitText (T 'sound.silenced') $stateColor 12))
        } else {
            if ($kind -eq 'playing') {
                $bars = New-Object Windows.Controls.StackPanel
                $bars.Orientation = 'Horizontal'; $bars.VerticalAlignment = 'Bottom'; $bars.Margin = '0,0,6,2'
                foreach ($h in 5, 8, 11) {
                    $r = New-Object Windows.Shapes.Rectangle
                    $r.Width = 3; $r.Height = $h; $r.Margin = '0,0,1,0'; $r.VerticalAlignment = 'Bottom'
                    $r.Fill = New-KitBrush $stateColor
                    [void]$bars.Children.Add($r)
                }
                [void]$line.Children.Add($bars)
            }
            [void]$line.Children.Add((New-KitText $(if ($kind -eq 'playing') { T 'sound.playing' } else { T 'sound.paused' }) $stateColor 12))
        }
        if ($a.Indexes.Count -gt 1) {
            [void]$line.Children.Add((New-KitText " $([char]0x00B7) $(T 'sound.app_sub' @([string]$a.Indexes.Count))" $t['textSecondary'] 12))
        }
        [void]$col.Children.Add($line)
        [Windows.Controls.Grid]::SetColumn($col, 1)
        [void]$top.Children.Add($col)
        $pct = New-KitText "$($a.Volume)%" $(if ($a.Muted) { $t['textSecondary'] } else { $t['text'] }) 15 -Bold
        if ($a.Muted) { $pct.TextDecorations = [Windows.TextDecorations]::Strikethrough }
        $pct.HorizontalAlignment = 'Right'; $pct.Margin = '8,0,10,0'
        [Windows.Controls.Grid]::SetColumn($pct, 2)
        [void]$top.Children.Add($pct)
        $ctx = @{ Indexes = @($a.Indexes); Pct = $pct }
        $mute = & $newMute $a.Muted $appGlyph { param($c, $m) foreach ($i in $c.Indexes) { try { [VivacAudio]::SetSessionMute($i, $m) } catch { } } } $ctx
        [Windows.Controls.Grid]::SetColumn($mute, 3)
        [void]$top.Children.Add($mute)
        [void]$stack.Children.Add($top)
        $fader = & $newFader $a.Volume $a.Muted { param($c, $l) foreach ($i in $c.Indexes) { try { [VivacAudio]::SetSessionVolume($i, $l) } catch { } }; $c.Pct.Text = "$l%" } $ctx
        $fader.Margin = '0,4,0,0'
        [void]$stack.Children.Add($fader)
        $card
    }

    $inputCard = {
        param($ins)
        $card = & $newCard $t['surface'] 12 '14,12'
        $stack = New-Object Windows.Controls.StackPanel
        $card.Child = $stack
        $head = & $section (T 'sound.input') $ins.Count '' $t['bg']
        $head.Margin = '0,0,0,8'
        [void]$stack.Children.Add($head)
        if (-not $ins.Count) {
            [void]$stack.Children.Add((New-KitText (T 'sound.none') $t['textSecondary'] 12))
            return $card
        }
        $default = @($ins | Where-Object { $_.IsDefault })[0]
        if (-not $default) { $default = $ins[0] }
        $others = @($ins | Where-Object { $_.Id -ne $default.Id })
        $entry = New-Object Windows.Controls.StackPanel
        $top = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto') { $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = $w })) }
        $ctx = @{ Id = $default.Id; Pct = $null }
        $mute = & $newMute $default.Muted $micGlyph { param($c, $m) try { [VivacAudio]::SetMute($c.Id, $m) } catch { } } $ctx
        $mute.Margin = '0,0,12,0'
        [void]$top.Children.Add($mute)
        $col = New-Object Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Center'
        [void]$col.Children.Add((& $newLabel (Get-SoundShortName $default.Name) $t['text'] 13 $true))
        [void]$col.Children.Add((& $newLabel (T 'sound.default') $t['textSecondary'] 12))
        [Windows.Controls.Grid]::SetColumn($col, 1)
        [void]$top.Children.Add($col)
        $pct = New-KitText "$($default.Volume)%" $(if ($default.Muted) { $t['textSecondary'] } else { $t['text'] }) 15 -Bold
        if ($default.Muted) { $pct.TextDecorations = [Windows.TextDecorations]::Strikethrough }
        $ctx.Pct = $pct
        [Windows.Controls.Grid]::SetColumn($pct, 2)
        [void]$top.Children.Add($pct)
        [void]$entry.Children.Add($top)
        $entry.ToolTip = $default.Name
        $fader = & $newFader $default.Volume $default.Muted { param($c, $l) try { [VivacAudio]::SetVolume($c.Id, $l) } catch { }; $c.Pct.Text = "$l%" } $ctx
        $fader.Margin = '0,6,0,0'
        [void]$entry.Children.Add($fader)
        [void]$stack.Children.Add($entry)
        if ($others.Count) {
            $fold = New-Object Windows.Controls.StackPanel
            $fold.Visibility = if ($state.InputsOpen) { 'Visible' } else { 'Collapsed' }
            foreach ($d in $others) {
                $row = New-KitRow $p 0xE720 (Get-SoundShortName $d.Name) (T 'sound.use')
                $row.Cursor = 'Hand'
                $row.ToolTip = $d.Name
                $row.Margin = '0,6,0,0'
                $row.Background = [Windows.Media.Brushes]::Transparent
                $row.Tag['Id'] = $d.Id
                $row.Tag['State'] = $state
                $row.Add_MouseLeftButtonUp({ param($s) try { [VivacAudio]::SetDefault([string]$s.Tag['Id']) } catch { }; & $s.Tag['State'].Render })
                [void]$fold.Children.Add($row)
            }
            $toggle = New-Object Windows.Controls.StackPanel
            $toggle.Orientation = 'Horizontal'; $toggle.Cursor = 'Hand'; $toggle.Margin = '0,10,0,0'
            $arrow = New-KitText $(if ($state.InputsOpen) { [string][char]0x25BE } else { [string][char]0x25B8 }) $t['textSecondary'] 12
            $arrow.Margin = '0,0,8,0'
            [void]$toggle.Children.Add($arrow)
            [void]$toggle.Children.Add((New-KitText (T 'sound.more_inputs' @([string]$others.Count)) $t['textSecondary'] 12))
            $toggle.Background = [Windows.Media.Brushes]::Transparent
            $toggle.Tag = @{ Fold = $fold; Arrow = $arrow; State = $state }
            $toggle.Add_MouseLeftButtonUp({
                    param($s)
                    $open = $s.Tag.Fold.Visibility -ne 'Visible'
                    $s.Tag.State.InputsOpen = $open
                    $s.Tag.Fold.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
                    $s.Tag.Arrow.Text = if ($open) { [string][char]0x25BE } else { [string][char]0x25B8 }
                })
            [void]$stack.Children.Add($toggle)
            [void]$stack.Children.Add($fold)
        }
        $card
    }

    $state.Render = {
        $data = Get-VivacSoundData
        $outs = @($data.Outputs); $ins = @($data.Inputs); $apps = @($data.Apps)
        $state.Signature = Get-SoundSignature $outs $ins $apps
        $sections.Children.Clear()
        $default = @($outs | Where-Object { $_.IsDefault })[0]
        if ($default) { $subtitle.Text = Get-SoundShortName $default.Name } else { $subtitle.Text = T 'sound.none' }
        $outCard = & $outputCard $outs
        $outCard.Margin = '0,0,0,14'
        [void]$sections.Children.Add($outCard)
        $appsHead = & $section (T 'sound.apps') $apps.Count '' $t['surface']
        $appsHead.Margin = '0,0,0,8'
        [void]$sections.Children.Add($appsHead)
        if (-not $apps.Count) {
            $none = New-KitText (T 'sound.no_apps') $t['textSecondary'] 12
            $none.TextWrapping = 'Wrap'; $none.Margin = '0,0,0,6'
            [void]$sections.Children.Add($none)
        }
        foreach ($a in $apps) { [void]$sections.Children.Add((& $appCard $a)) }
        $inCard = & $inputCard $ins
        $inCard.Margin = '0,8,0,0'
        [void]$sections.Children.Add($inCard)
    }

    # Follow the machine: an application starting or stopping, a device
    # plugged, a level moved elsewhere. Windows has no event here that does not
    # need a COM sink, so the panel looks every second and a half and redraws
    # only when the answer changed and no fader is held.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $timer.Add_Tick({
            if ($state.Dragging -or [Windows.Input.Mouse]::LeftButton -eq 'Pressed') { return }
            $data = Get-VivacSoundData
            if ((Get-SoundSignature @($data.Outputs) @($data.Inputs) @($data.Apps)) -ne $state.Signature) { & $state.Render }
        })
    $window.Resources['vivac.soundTimer'] = $timer
    $window.Add_Closed({ param($s) $s.Resources['vivac.soundTimer'].Stop() })
    $window.Add_PreviewKeyDown({ param($s, $e) if ([string]$e.Key -eq 'Escape') { $window.Close(); $e.Handled = $true } })
    & $state.Render
    if ($NoShow) { return $window }
    $timer.Start()
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# ------------------------------------------------------- clipboard history

# What Win+V shows: everything copied since the resident host started, text
# and pictures, newest first, as cliphist keeps it in the source. It is held
# in memory only -- never written to disk, gone when the host stops -- and a
# copy that asks not to be recorded (password managers such as KeePassXC mark
# theirs) is not recorded.
$script:ClipHistory = New-Object System.Collections.Generic.List[object]
$script:ClipMax = 60

function Test-ClipboardPrivate($Data) {
    foreach ($fmt in 'ExcludeClipboardContentFromMonitorProcessing', 'Clipboard Viewer Ignore') {
        if ($Data.GetDataPresent($fmt)) { return $true }
    }
    # CanIncludeInClipboardHistory is a DWORD: 0 means "do not keep this".
    if ($Data.GetDataPresent('CanIncludeInClipboardHistory')) {
        $s = $Data.GetData('CanIncludeInClipboardHistory')
        if ($s -is [IO.Stream]) { $b = New-Object byte[] 4; [void]$s.Read($b, 0, 4); if ([BitConverter]::ToInt32($b, 0) -eq 0) { return $true } }
    }
    $false
}

# Called by the host each time Windows reports a copy.
function Add-VivacClipboardEntry {
    Add-Type -AssemblyName PresentationCore
    $data = [Windows.Clipboard]::GetDataObject()
    if (-not $data -or (Test-ClipboardPrivate $data)) { return }
    $entry = $null
    if ([Windows.Clipboard]::ContainsText()) {
        $text = [Windows.Clipboard]::GetText()
        if (-not $text.Trim()) { return }
        $entry = New-ClipEntry 'text' $text
    } elseif ([Windows.Clipboard]::ContainsImage()) {
        $img = [Windows.Clipboard]::GetImage()
        if (-not $img) { return }
        $img.Freeze()
        $entry = New-ClipEntry 'image' '' $img
    }
    if (-not $entry) { return }
    # Copying something again moves it to the top instead of repeating it.
    for ($i = $script:ClipHistory.Count - 1; $i -ge 0; $i--) {
        $old = $script:ClipHistory[$i]
        if ($old.Kind -eq 'text' -and $entry.Kind -eq 'text' -and $old.Text -ceq $entry.Text) { $script:ClipHistory.RemoveAt($i) }
    }
    $script:ClipHistory.Insert(0, $entry)
    while ($script:ClipHistory.Count -gt $script:ClipMax) { $script:ClipHistory.RemoveAt($script:ClipHistory.Count - 1) }
}

function Get-VivacClipboardHistory { , $script:ClipHistory }

$script:PasteNative = $null
function Get-PasteNative {
    if (-not ('Vivac.Paste' -as [type])) {
        Add-Type -Namespace Vivac -Name Paste -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
    }
    [Vivac.Paste]
}

# Picking a row puts it back on the clipboard and pastes it where the cursor
# was, as Windows' Win+V does; Del forgets one row, Shift+Del all of them.
#
# The panel is the Linux side's (linux/lib/vivacpanel/clipboard.py): a search
# box with the match count, filter chips with counters, the history on the
# left and the selected entry on the right with its actions. What looks like
# a secret is drawn as a mask and never matches a search; what a password
# manager marks private is not recorded at all (Test-ClipboardPrivate).
function Show-Clipboard([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'clipboard' }
    $surfaceName = 'clipboard'
    $p = Get-Palette
    $t = Get-KitTokens $p
    $native = Get-PasteNative
    $previous = $native::GetForegroundWindow()
    $arrows = "$([char]0x2191)$([char]0x2193)"
    $hints = @(@($arrows, (T 'clip.key.select')), @([string][char]0x21B5, (T 'clip.key.paste')),
        @((T 'clip.key.del'), (T 'clip.key.forget')), @("$([char]0x21E7)$(T 'clip.key.del')", (T 'clip.key.forget_all')),
        @('Esc', (T 'clip.key.close')), @('Tab', (T 'clip.key.filter')))
    $body = @"
<StackPanel>
  <Grid Margin="0,0,0,10">
    <Border Background="#$($t['surface'])" BorderBrush="#$($t['focusRing'])" BorderThickness="2" CornerRadius="10" Height="42"/>
    <TextBox x:Name="Filter" Height="38" Margin="2" Padding="12,0" FontSize="14" Background="Transparent" BorderThickness="0"
             VerticalContentAlignment="Center" Foreground="#$($t['text'])" CaretBrush="#$($t['accent'])"/>
    <TextBlock x:Name="Placeholder" IsHitTestVisible="False" Margin="14,0,0,0" VerticalAlignment="Center" FontSize="14" Foreground="#80$($t['textSecondary'])"/>
    <TextBlock x:Name="CountOf" IsHitTestVisible="False" Margin="0,0,14,0" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="12" Foreground="#$($t['textSecondary'])"/>
  </Grid>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="290"/></Grid.ColumnDefinitions>
    <StackPanel>
      <StackPanel x:Name="Chips" Orientation="Horizontal" Margin="0,0,0,8"/>
      <Border Background="#$($t['surface'])" CornerRadius="10" Padding="4">
        <ScrollViewer x:Name="Scroll" MaxHeight="440" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="Rows"/>
        </ScrollViewer>
      </Border>
    </StackPanel>
    <Border x:Name="Detail" Grid.Column="2" Background="#$($t['surface'])" CornerRadius="12" Padding="14" VerticalAlignment="Top">
      <StackPanel x:Name="DetailBody"/>
    </Border>
  </Grid>
</StackPanel>
"@
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - clipboard' 820 (Get-KitPanelXamlV2 $t ([string][char]0xE77F) (T 'clip.title') $body $hints))
    Add-KitDrawResources $window $p
    $rowsBox = $window.FindName('Rows')
    $filter = $window.FindName('Filter')
    $chipsBox = $window.FindName('Chips')
    $detailBody = $window.FindName('DetailBody')
    $window.FindName('Placeholder').Text = T 'clip.search'
    $subtitle = $window.FindName('Subtitle')
    $countOf = $window.FindName('CountOf')
    $placeholder = $window.FindName('Placeholder')

    $wipe = New-Object Windows.Controls.Button
    $wipe.Style = $window.FindResource('KitOutline')
    $wipeRow = New-Object Windows.Controls.StackPanel
    $wipeRow.Orientation = 'Horizontal'
    $wg = New-KitGlyph 0xE74D $t['alert'] 12
    $wg.Margin = '0,0,8,0'
    $wipeRow.Children.Add($wg) | Out-Null
    $wipeLabel = New-KitText (T 'clip.forget_all') $t['alert'] 12
    $wipeRow.Children.Add($wipeLabel) | Out-Null
    $wipe.Content = $wipeRow
    $wipe.Tag = @{ Glyph = $wg; Label = $wipeLabel; Tokens = $t }
    # The outline fills with the alert colour under the pointer, so its text
    # turns to the panel's colour with it.
    $wipe.Add_MouseEnter({ param($s) $s.Tag.Glyph.Foreground = New-KitBrush $s.Tag.Tokens['bg']; $s.Tag.Label.Foreground = New-KitBrush $s.Tag.Tokens['bg'] })
    $wipe.Add_MouseLeave({ param($s) $s.Tag.Glyph.Foreground = New-KitBrush $s.Tag.Tokens['alert']; $s.Tag.Label.Foreground = New-KitBrush $s.Tag.Tokens['alert'] })
    [void]$window.FindName('HeaderRight').Children.Add($wipe)

    # What the handlers share: the filter chip, the selected row, what the
    # search and the chip leave on screen.
    $state = @{ Filter = 'all'; Index = 0; Shown = @(); Total = 0 }
    $kindGlyph = @{ text = 0xE8A5; link = 0xE71B; image = 0xE91B; private = 0xE72E }

    $describe = {
        param($e)
        if ($e.Kind -eq 'image') { return @((T 'clip.image' @([string]$e.Width, [string]$e.Height)), (T 'clip.kind.image')) }
        if ($e.Private) { return @((Get-ClipMask), (T 'clip.private_sub')) }
        $parts = @()
        if ($e.Lines -gt 1) { $parts += T 'clip.lines' @([string]($e.Lines - 1)) }
        $parts += T 'clip.chars' @([string]$e.Chars)
        @($e.First, ($parts -join " $([char]0x00B7) "))
    }

    $row = {
        param($e, [int]$I)
        $selected = $I -eq $state.Index
        $fg = if ($selected) { $t['actionText'] } else { $t['text'] }
        $dim = if ($selected) { $t['actionText'] } else { $t['textSecondary'] }
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = 8; $b.Padding = '8,6'; $b.Margin = '0,0,0,2'; $b.MinHeight = 44
        $b.Background = if ($selected) { New-KitBrush $t['actionFill'] } else { [Windows.Media.Brushes]::Transparent }
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*', 'Auto') { $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = $w })) }
        $tile = New-Object Windows.Controls.Border
        $tile.Width = 32; $tile.Height = 32; $tile.CornerRadius = 8; $tile.VerticalAlignment = 'Center'
        $tile.Background = if ($selected) { New-KitBrush "26$($t['actionText'])" } else { New-KitBrush $t['surfaceAlt'] }
        $tile.Child = New-KitGlyph $kindGlyph[(Get-ClipKind $e)] $(if ($selected) { $t['actionText'] } else { $t['accent'] }) 16
        $tile.Child.HorizontalAlignment = 'Center'
        [void]$g.Children.Add($tile)
        $text = & $describe $e
        $col = New-Object Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Center'; $col.Margin = '12,0,8,0'
        $name = New-KitText $text[0] $fg 13
        $name.TextTrimming = 'CharacterEllipsis'
        if ($selected) { $name.FontWeight = 'Bold' }
        $sub = New-KitText $text[1] $dim 11
        $sub.TextTrimming = 'CharacterEllipsis'
        [void]$col.Children.Add($name); [void]$col.Children.Add($sub)
        [Windows.Controls.Grid]::SetColumn($col, 1)
        [void]$g.Children.Add($col)
        $end = $null
        if ($e.Kind -eq 'image' -and $e.Image) {
            $end = New-Object Windows.Controls.Image
            $end.Source = $e.Image; $end.MaxWidth = 96; $end.MaxHeight = 36; $end.Stretch = 'Uniform'
            [Windows.Media.RenderOptions]::SetBitmapScalingMode($end, 'HighQuality')
        } elseif ($e.Private) {
            $end = New-Object Windows.Controls.Border
            $end.CornerRadius = 8; $end.Padding = '6,1'
            $end.Background = New-KitBrush $(if ($selected) { "26$($t['actionText'])" } else { "40$($t['accent'])" })
            $end.Child = New-KitText (T 'clip.private') $(if ($selected) { $t['actionText'] } else { $t['accent'] }) 11 -Bold
        }
        if ($end) {
            $end.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($end, 2)
            [void]$g.Children.Add($end)
        }
        $b.Child = $g
        # No tooltip: a secret is never shown, not even there.
        $b.Tag = @{ Index = $I; State = $state }
        if (-not $selected) {
            $b.Add_MouseEnter({ param($s) $s.Background = New-KitBrush $s.Tag.State.Hover })
            $b.Add_MouseLeave({ param($s) $s.Background = [Windows.Media.Brushes]::Transparent })
        }
        $b.Add_MouseLeftButtonDown({
                param($s, $ev)
                $s.Tag.State.Index = $s.Tag.Index
                & $s.Tag.State.Render
                if ($ev.ClickCount -ge 2) { & $s.Tag.State.Paste }
                $ev.Handled = $true
            })
        $b
    }
    $state.Hover = $t['surfaceAlt']

    $drawChips = {
        $chipsBox.Children.Clear()
        $n = Get-ClipCounts $script:ClipHistory.ToArray()
        foreach ($kind in (Get-ClipKinds)) {
            $on = $kind -eq $state.Filter
            $chip = New-KitChip $window $t (T "clip.f.$kind") ([string]$n[$kind]) -Selected:$on -NoRing
            if (-not $on) { $chip.Background = New-KitBrush $t['surface'] }
            $chip.Margin = '0,0,6,0'
            $chip.Tag['Kind'] = $kind
            $chip.Tag['State'] = $state
            $chip.Add_Click({ param($s) $s.Tag['State'].Filter = $s.Tag['Kind']; $s.Tag['State'].Index = 0; & $s.Tag['State'].Render })
            [void]$chipsBox.Children.Add($chip)
        }
    }

    $drawDetail = {
        $detailBody.Children.Clear()
        if (-not $state.Shown.Count) { $window.FindName('Detail').Visibility = 'Hidden'; return }
        $window.FindName('Detail').Visibility = 'Visible'
        $e = $state.Shown[$state.Index]
        $kind = Get-ClipKind $e
        $head = New-Object Windows.Controls.Grid
        $head.Margin = '0,0,0,10'
        $head.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
        $head.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $cap = New-KitText (T 'clip.preview').ToUpper() $t['accent'] 11 -Bold
        $cap.Margin = '4,0,0,0'
        $tag = New-Object Windows.Controls.StackPanel
        $tag.Orientation = 'Horizontal'
        $tg = New-KitGlyph $kindGlyph[$kind] $t['textSecondary'] 12
        $tg.Margin = '0,0,8,0'
        [void]$tag.Children.Add($tg)
        [void]$tag.Children.Add((New-KitText (T "clip.kind.$kind") $t['textSecondary'] 12))
        [Windows.Controls.Grid]::SetColumn($tag, 1)
        [void]$head.Children.Add($cap); [void]$head.Children.Add($tag)
        [void]$detailBody.Children.Add($head)
        $pane = New-Object Windows.Controls.Border
        $pane.Background = New-KitBrush $t['bg']; $pane.CornerRadius = 10; $pane.Padding = '12'; $pane.Height = 220
        if ($e.Kind -eq 'image' -and $e.Image) {
            $img = New-Object Windows.Controls.Image
            $img.Source = $e.Image; $img.Stretch = 'Uniform'; $img.StretchDirection = 'DownOnly'
            [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
            $pane.Child = $img
        } else {
            $shown = if ($e.Private) { Get-ClipMask } else { $e.Text }
            # A long text is cut for the panel: the whole of it is still what a paste puts back.
            if ($shown.Length -gt 6000) { $shown = $shown.Substring(0, 6000) + [string][char]0x2026 }
            $tb = New-KitText $shown $(if ($e.Private) { $t['accent'] } else { $t['text'] }) 13
            $tb.TextWrapping = 'Wrap'; $tb.VerticalAlignment = 'Top'
            $sv = New-Object Windows.Controls.ScrollViewer
            $sv.VerticalScrollBarVisibility = 'Auto'; $sv.HorizontalScrollBarVisibility = 'Disabled'
            $sv.Content = $tb
            $pane.Child = $sv
        }
        [void]$detailBody.Children.Add($pane)
        $stats = New-Object Windows.Controls.StackPanel
        $stats.Orientation = 'Horizontal'; $stats.Margin = '0,10,0,10'
        $parts = if ($e.Kind -eq 'image') { @("$($e.Width)$([char]0x00D7)$($e.Height)") }
        elseif ($e.Private) { @((T 'clip.private_sub')) }
        else { @((T 'clip.n_lines' @([string]$e.Lines)), (T 'clip.chars' @([string]$e.Chars))) }
        foreach ($s in $parts) {
            $x = New-KitText $s $t['textSecondary'] 12
            $x.Margin = '0,0,16,0'
            [void]$stats.Children.Add($x)
        }
        [void]$detailBody.Children.Add($stats)
        $buttons = New-Object Windows.Controls.Grid
        $buttons.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
        $buttons.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $go = New-Object Windows.Controls.Button
        $go.Style = $window.FindResource('KitActionPrimary')
        $go.Content = "$(T 'clip.paste')  $([char]0x21B5)"
        $go.Height = 44
        $go.Tag = $state
        $go.Add_Click({ param($s) & $s.Tag.Paste })
        $del = New-Object Windows.Controls.Button
        $del.Style = $window.FindResource('KitActionDanger')
        $dr = New-Object Windows.Controls.StackPanel
        $dr.Orientation = 'Horizontal'
        $dgl = New-KitGlyph 0xE74D $t['text'] 12
        $dgl.Margin = '0,0,8,0'
        [void]$dr.Children.Add($dgl)
        [void]$dr.Children.Add((New-KitText (T 'clip.forget') $t['text'] 12))
        $del.Content = $dr
        $del.Margin = '8,0,0,0'
        $del.Height = 44
        $del.Tag = @{ State = $state; Entry = $e }
        $del.Add_Click({ param($s) [void]$script:ClipHistory.Remove($s.Tag.Entry); & $s.Tag.State.Render })
        [Windows.Controls.Grid]::SetColumn($del, 1)
        [void]$buttons.Children.Add($go); [void]$buttons.Children.Add($del)
        [void]$detailBody.Children.Add($buttons)
    }

    $state.Render = {
        & $drawChips
        $pool = Select-ClipByKind $script:ClipHistory.ToArray() $state.Filter
        $state.Shown = @(Select-ClipFiltered $pool $filter.Text)
        $state.Total = $script:ClipHistory.Count
        $state.Index = [Math]::Max(0, [Math]::Min($state.Index, $state.Shown.Count - 1))
        $subtitle.Text = T 'clip.count' @([string]$state.Total)
        $countOf.Text = T 'clip.of' @([string]$state.Shown.Count, [string]$state.Total)
        $placeholder.Visibility = if ($filter.Text) { 'Hidden' } else { 'Visible' }
        & $drawDetail
        $rowsBox.Children.Clear()
        if (-not $state.Shown.Count) {
            $msg = if (-not $state.Total) { T 'clip.none' } else { T 'clip.no_match' }
            $none = New-KitText $msg $t['textSecondary'] 12
            $none.TextWrapping = 'Wrap'; $none.Margin = '10,8'
            [void]$rowsBox.Children.Add($none)
            return
        }
        $selected = $null
        for ($i = 0; $i -lt $state.Shown.Count; $i++) {
            $r = & $row $state.Shown[$i] $i
            if ($i -eq $state.Index) { $selected = $r }
            [void]$rowsBox.Children.Add($r)
        }
        # Scrolled to once it has a place: a row not yet laid out has nowhere to scroll to.
        if ($selected) { $selected.Add_Loaded({ param($s) $s.BringIntoView() }) }
    }

    $state.Paste = {
        if (-not $state.Shown.Count) { return }
        $e = $state.Shown[$state.Index]
        if ($e.Kind -eq 'image') { [Windows.Clipboard]::SetImage($e.Image) } else { [Windows.Clipboard]::SetText($e.Text) }
        $window.Close()
        if ($previous -ne [IntPtr]::Zero) {
            [void]$native::SetForegroundWindow($previous)
            Start-Sleep -Milliseconds 80
            $native::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
            $native::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
            $native::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
            $native::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
        }
    }

    $wipe.Tag['State'] = $state
    $wipe.Add_Click({ param($s) $script:ClipHistory.Clear(); & $s.Tag['State'].Render })
    $filter.Tag = $state
    $filter.Add_TextChanged({ param($s) $s.Tag.Index = 0; & $s.Tag.Render })
    $window.Add_PreviewKeyDown({
        param($s, $ev)
        $k = [string]$ev.Key
        $kinds = @(Get-ClipKinds)
        if ($k -eq 'Escape') { $window.Close(); $ev.Handled = $true; return }
        if ($k -eq 'Down' -or $k -eq 'Up') {
            if ($state.Shown.Count) {
                $step = if ($k -eq 'Down') { 1 } else { -1 }
                $state.Index = [Math]::Max(0, [Math]::Min($state.Shown.Count - 1, $state.Index + $step))
                & $state.Render
            }
            $ev.Handled = $true; return
        }
        if ($k -eq 'Tab') {
            $back = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)
            $at = [Array]::IndexOf($kinds, $state.Filter)
            $state.Filter = $kinds[($at + $(if ($back) { -1 } else { 1 }) + $kinds.Count) % $kinds.Count]
            $state.Index = 0
            & $state.Render
            $ev.Handled = $true; return
        }
        if ($k -eq 'Return') { & $state.Paste; $ev.Handled = $true; return }
        if ($k -eq 'Delete') {
            if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) { $script:ClipHistory.Clear() }
            elseif ($state.Shown.Count) { [void]$script:ClipHistory.Remove($state.Shown[$state.Index]) }
            & $state.Render; $ev.Handled = $true; return
        }
    })
    $window.Add_ContentRendered({ $filter.Focus() | Out-Null })
    & $state.Render
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

# ------------------------------------------------------------------- lock

# Set before the first lock: under strict mode an unset one is an error, and
# the greeter at sign-in failed on it.
$script:LockShown = $false

# Win+L: vivac's lock, the counterpart of the source's hyprlock -- the base
# colour of the theme on every screen, a large clock, and a password field
# outlined in the accent. It is drawn by the resident host, and a window is
# not a lock by itself, so it leans on Windows' own lock at every edge:
#
#   - the keyboard hook turns away what would get around it (Win, Alt+Tab,
#     Alt+F4, Ctrl+Esc, Ctrl+Shift+Esc) while it is up
#   - Ctrl+Alt+Del cannot be turned away by anything, so the moment Windows
#     switches to its secure screen the session is locked by Windows itself
#     and vivac's lock steps aside: what is behind it is then Windows' lock
#   - a separate watchdog process locks the session the Windows way if the
#     host dies while vivac's lock is up
#
# Unlocking: Enter on an empty field asks Windows Hello (the PIN, a finger, a
# face); a password typed into the field is checked against Windows with
# LogonUser and dropped at once. Nothing is stored. Without the resident host
# (bin\vivac.ps1 lock) the lock is Windows' own, wearing the theme's picture.
function Invoke-VivacLock([switch]$Greeter) {
    Update-SurfaceContext
    try {
        Import-Module (Join-Path $root 'lib\Desktop.psm1')
        if (Test-VivacLockScreenManaged) {
            [void](Update-VivacLockScreen (Get-VivacWallpaper -Theme (Read-VivacTheme $settings['theme'])))
        }
    } catch { }
    if (('VivacKeys' -as [type]) -and ($script:LockShown -ne $true)) {
        $script:LockShown = $true
        # Marked for the pull (see Invoke-VivacWithLockMarker): the start-up
        # cover's marker, when there is one, is left alone.
        try { [void](Invoke-VivacWithLockMarker 'lock' { Show-VivacLock -Greeter:$Greeter }) } finally { $script:LockShown = $false }
        return
    }
    # Windows' own lock takes over: the cover must not stay behind it, or the
    # desktop is hidden after the unlock.
    Hide-VivacLockCover
    Invoke-VivacLockFallback
}

# Windows' own lock, from wherever the lock was: the greeter's own desktop
# (lib\Greeter.psm1) steps aside first, or the unlock would land on an empty
# one. On Default this is just the lock.
function Invoke-VivacLockFallback {
    try { $n = Get-LockNative; if ($n::InputDesktopName() -ne 'Default') { [void]$n::SwitchToDefault() } } catch { }
    Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation'
}

# Lock failures are the one thing the daemon cannot show on screen: they go
# to a file next to its other state.
function Write-VivacLockLog([string]$Text) {
    try {
        $log = Join-Path (Get-VivacPaths).State 'lock.log'
        $dir = Split-Path -Parent $log
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0}  {1}' -f (Get-Date -Format s), $Text) -Encoding UTF8
    } catch { }
}

function Get-LockNative {
    if (-not ('VivacLockNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class VivacLockNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int length, out int needed);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();
    // Interactive logon, checked and closed: the token is never used.
    public static bool CheckPassword(string user, string domain, string password) {
        IntPtr token;
        bool ok = LogonUser(user, domain, password, 2, 0, out token);
        if (ok) CloseHandle(token);
        return ok;
    }
    // The desktop that has the keyboard, by name: "Default" while the
    // user's own session shows, the greeter's own at sign-in
    // (lib\Greeter.psm1); null (no access at all) means Windows' secure
    // screen -- Ctrl+Alt+Del, its lock, a UAC prompt -- has it.
    public static string InputDesktopName() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001);
        if (d == IntPtr.Zero) return null;
        try {
            StringBuilder name = new StringBuilder(128); int needed;
            if (!GetUserObjectInformation(d, 2, name, name.Capacity * 2, out needed)) return null;
            return name.ToString();
        } finally { CloseDesktop(d); }
    }
    public static bool OnDesktop(string desktop) {
        string name = InputDesktopName();
        return name != null && string.Equals(name, desktop, StringComparison.OrdinalIgnoreCase);
    }
    public static bool OnUserDesktop() { return OnDesktop("Default"); }
    // The programs' desktop back on screen, before Windows' own lock: an
    // unlock must not land on the greeter's empty desktop. False when the
    // secure screen has the input (it cannot be opened); nothing to do then.
    public static bool SwitchToDefault() { return SwitchTo("Default"); }
    // Any desktop of the session on screen, by name; false when it cannot
    // be opened or switched to (the secure screen is up).
    public static bool SwitchTo(string desktop) {
        IntPtr d = OpenDesktop(desktop, 0, false, 0x0100);
        if (d == IntPtr.Zero) return false;
        try { return SwitchDesktop(d); } finally { CloseDesktop(d); }
    }
}
'@
    }
    [VivacLockNative]
}

# Windows Hello's prompt. Asked for the lock's own window (Window), the
# prompt belongs to it: it opens in front of the lock and has the keyboard.
# Asked without one, Windows puts it wherever it likes, which behind a
# full-screen lock is nowhere to be seen.
function Start-HelloVerification([IntPtr]$Window = [IntPtr]::Zero) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $verifier = [Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]
    $result = [Windows.Security.Credentials.UI.UserConsentVerificationResult]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $asTask = $asTask.MakeGenericMethod($result)
    $message = T 'lock.hello_message'
    if ($Window -ne [IntPtr]::Zero) {
        try {
            if (-not ('VivacHelloInterop' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("39E050C3-4E74-441A-8DC0-B81104DF949C"), InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
public interface IVivacUserConsentVerifierInterop {
    [return: MarshalAs(UnmanagedType.IUnknown)]
    object RequestVerificationForWindowAsync(IntPtr appWindow, [MarshalAs(UnmanagedType.HString)] string message, [In] ref Guid riid);
}
public static class VivacHelloInterop {
    public static object Request(object factory, IntPtr window, string message, Guid iid) {
        return ((IVivacUserConsentVerifierInterop)factory).RequestVerificationForWindowAsync(window, message, ref iid);
    }
}
'@
            }
            # The interface asked for: IAsyncOperation<UserConsentVerificationResult>.
            $iid = $asTask.GetParameters()[0].ParameterType.GUID
            $factory = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeMarshal]::GetActivationFactory($verifier)
            return $asTask.Invoke($null, @([VivacHelloInterop]::Request($factory, $Window, $message, $iid)))
        } catch { Write-VivacLockLog "Windows Hello for the lock's window failed, asked without it: $_" }
    }
    $asTask.Invoke($null, @($verifier::RequestVerificationAsync($message)))
}

# How the lock asks to be unlocked: pin (Windows Hello's prompt, where the
# PIN, a finger or a face go) or password (the field, checked with
# LogonUser). Tab switches; the way last used to get in is the next one.
function Get-VivacLockMode {
    $path = Join-Path (Get-VivacPaths).State 'lock-mode'
    try { if ((Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim() -eq 'password') { return 'password' } } catch { }
    'pin'
}
function Set-VivacLockMode([ValidateSet('pin', 'password')][string]$Mode) {
    try { Write-VivacFile -Path (Join-Path (Get-VivacPaths).State 'lock-mode') -Text "$Mode`n" } catch { Write-VivacLockLog "lock mode not kept: $_" }
}
# A PIN typed into the password field: only digits, as long as a PIN is.
function Test-VivacLooksLikePin([string]$Text) { $Text -match '^\d{4,12}$' }

# At sign-in (bin\vivac-greeter.ps1, on the greeter's own desktop; or a host
# started with -LockAtStart) the screens are covered in the theme's base
# colour the moment the process starts, before it has built anything else;
# vivac's lock then opens on top, and the cover goes away with it on unlock.
$script:LockCover = @()
# Set once vivac's lock has rendered over the cover (Show-VivacLock).
$script:LockGreeterUp = $false
# How the cover hands over when the greeter never shows: Windows' own lock.
$script:LockFallback = { Invoke-VivacLockFallback }
# The greeter gets this long to show before the cover gives up on it.
$script:LockCoverGraceSeconds = 60
# A topmost window over one screen, the screen's exact size.
function Set-VivacScreenWindow($Window, $Screen) {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96.0; $g.Dispose()
    $b = $Screen.Bounds
    $Window.WindowStartupLocation = 'Manual'
    $Window.Topmost = $true
    $Window.Left = $b.Left / $scale; $Window.Top = $b.Top / $scale
    $Window.Width = $b.Width / $scale; $Window.Height = $b.Height / $scale
}
function Show-VivacLockCover([switch]$NoShow) {
    Update-SurfaceContext
    $p = Get-Palette
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
    $script:LockGreeterUp = $false
    $script:LockCover = @(foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $w = New-Object Windows.Window
            $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.ShowInTaskbar = $false
            $w.Background = "#$($p['COLOR_BG'])"; $w.Cursor = [Windows.Input.Cursors]::None; $w.Title = 'vivac - lock'
            Set-VivacScreenWindow $w $screen
            if (-not $NoShow) { $w.Show() }
            $w
        })
    if ($NoShow) { return $script:LockCover }
    Write-VivacLockLog 'sign-in cover up'
    # The cover never outlives a greeter that does not come: past the grace,
    # Windows' own lock takes over and the desktop is not left hidden.
    $grace = New-Object Windows.Threading.DispatcherTimer
    $grace.Interval = [TimeSpan]::FromSeconds($script:LockCoverGraceSeconds)
    $grace.Add_Tick({ param($s, $e) $s.Stop(); Invoke-VivacLockCoverGrace })
    $grace.Start()
}
# The grace's verdict, on its own so it can be checked without waiting.
function Invoke-VivacLockCoverGrace {
    if (-not @($script:LockCover).Count -or $script:LockGreeterUp) { return }
    Write-VivacLockLog "the greeter did not show in $($script:LockCoverGraceSeconds) s: cover dropped, Windows' own lock instead"
    Hide-VivacLockCover
    & $script:LockFallback
}
# Drops the cover without unlocking: when the lock itself could not be shown,
# the desktop must not stay hidden behind blank windows.
function Hide-VivacLockCover {
    foreach ($w in $script:LockCover) { try { $w.Close() } catch { } }
    $script:LockCover = @()
}
# The lock's windows and the cover under them go on top, or step back (for
# Windows Hello's prompt), together: a cover left on top would hide both the
# lock and the prompt, with nothing on screen to type into.
function Set-VivacLockTopmost([bool]$On, [object[]]$Windows) {
    foreach ($w in @($Windows) + @($script:LockCover)) { if ($w) { $w.Topmost = $On } }
}
# The account to check a typed password against. After an automatic
# sign-in, Winlogon names the spelling Windows accepted for it (a Microsoft
# account signs in as its e-mail, not as the profile's folder name), which
# scripts\set-autologon.ps1 found and recorded; then the session's own.
function Get-LockAccounts {
    $accounts = @()
    $wl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($wl -and $wl.PSObject.Properties['DefaultUserName'] -and $wl.DefaultUserName) {
        $domain = $null
        if ($wl.PSObject.Properties['DefaultDomainName'] -and $wl.DefaultDomainName) { $domain = [string]$wl.DefaultDomainName }
        $accounts += , @([string]$wl.DefaultUserName, $domain)
    }
    $accounts += , @($env:USERNAME, $env:USERDOMAIN)
    $accounts
}

# The greeter (-Greeter): what the lock becomes at sign-in, after Windows has
# signed in by itself. It wears the look of the bar's hover popups
# (templates\zebar\vivac\styles.css.in): panels in the base colour with
# twelve-pixel corners and the accent rule under them, the heading in the
# accent, facts in a strip of the surface colour, key caps at the foot. The
# theme's wallpaper is behind it, veiled in the base colour, and the account
# has its Windows picture and full name. Restart and shut down ask for a
# second press.
function Get-GreeterXaml($p, [bool]$PasswordOnly = $false) {
    $name = $env:USERNAME
    try { $full = [string](Get-LocalUser -Name $env:USERNAME -ErrorAction Stop).FullName; if ($full) { $name = $full } } catch { }
    $account = [string](@(Get-LockAccounts | ForEach-Object { $_[0] } | Where-Object { $_ -match '@' }) + '')[0]
    $hour = (Get-Date).Hour
    $greeting = T $(if ($hour -ge 6 -and $hour -lt 14) { 'greeter.morning' } elseif ($hour -ge 14 -and $hour -lt 21) { 'greeter.afternoon' } else { 'greeter.evening' })
    $theme = [string]$settings['theme']
    try { $theme = [string](Read-VivacTheme $settings['theme']).Title } catch { }
    if (-not $theme) { $theme = [string]$settings['theme'] }
    $online = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $hints = @(, @('Intro', (T 'greeter.hint_enter')))
    if (-not $PasswordOnly) { $hints += , @('Tab', (T 'greeter.hint_mode')) }
    $hints += , @('Esc', (T 'greeter.hint_clear'))
    $net = T $(if ($online) { 'greeter.online' } else { 'greeter.offline' })
    $netColor = $(if ($online) { $p['COLOR_INFO'] } else { $p['COLOR_MUTED'] })
    $accountVis = $(if ($account) { 'Visible' } else { 'Collapsed' })
    $kt = Get-PanelTokens $p
    $x = { param($s) ConvertTo-XmlText ([string]$s) }
    $fact = { param($label, $value, $col) "<StackPanel Grid.Column=`"$col`" HorizontalAlignment=`"Center`"><TextBlock HorizontalAlignment=`"Center`" FontSize=`"11`" Foreground=`"#$($p['COLOR_FG_DIM'])`" Text=`"$(& $x $label)`"/><TextBlock HorizontalAlignment=`"Center`" FontSize=`"12`" Margin=`"0,2,0,0`" Text=`"$(& $x $value)`" TextTrimming=`"CharacterEllipsis`"/></StackPanel>" }
    @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - lock" WindowStyle="None" ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        Background="#$($p['COLOR_BG'])"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" Foreground="#$($p['COLOR_FG'])">
  <Grid>
    <Grid.Resources>
$(Get-KitResourcesXaml $p)
    </Grid.Resources>
    <Image x:Name="Backdrop" Stretch="UniformToFill"/>
    <Rectangle>
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Offset="0" Color="#8C$($p['COLOR_BG'])"/>
          <GradientStop Offset="0.5" Color="#B3$($p['COLOR_BG'])"/>
          <GradientStop Offset="1" Color="#E6$($p['COLOR_BG'])"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
    </Rectangle>

    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,24">
      <TextBlock x:Name="Clock" HorizontalAlignment="Center" FontSize="112" FontWeight="Bold" Foreground="#$($p['COLOR_FG'])"/>
      <TextBlock x:Name="Day" HorizontalAlignment="Center" FontSize="17" Foreground="#$($p['COLOR_FG_DIM'])" Margin="0,0,0,34"/>

      <Border x:Name="Card" Width="360" Padding="0" Opacity="0" Background="Transparent">
        <Border.RenderTransform><TranslateTransform x:Name="CardShift" Y="18"/></Border.RenderTransform>
        <Border.Triggers>
          <EventTrigger RoutedEvent="FrameworkElement.Loaded">
            <BeginStoryboard><Storyboard>
              <DoubleAnimation Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.45"/>
              <DoubleAnimation Storyboard.TargetName="CardShift" Storyboard.TargetProperty="Y" To="0" Duration="0:0:0.45">
                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
              </DoubleAnimation>
            </Storyboard></BeginStoryboard>
          </EventTrigger>
        </Border.Triggers>
        <StackPanel>
          <Grid Width="64" Height="64" HorizontalAlignment="Center">
            <Ellipse Fill="#$($p['COLOR_ACCENT'])"/>
            <TextBlock Text="$(& $x $name.Substring(0, 1).ToUpper())" FontSize="26" FontWeight="Bold" Foreground="#$($p['COLOR_BG'])"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Ellipse x:Name="Avatar"/>
          </Grid>
          <TextBlock HorizontalAlignment="Center" Margin="0,10,0,0" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" Text="$(& $x $greeting)"/>
          <TextBlock HorizontalAlignment="Center" Margin="0,0,0,0" FontSize="15" FontWeight="Bold" Text="$(& $x $name)"/>
          <TextBlock HorizontalAlignment="Center" Margin="0,2,0,0" FontSize="12" Foreground="#$($p['COLOR_MUTED'])" Text="$(& $x $account)" Visibility="$accountVis"/>

          <Border x:Name="Field" Height="40" CornerRadius="12" Margin="0,12,0,0" BorderThickness="2"
                  BorderBrush="#$($p['COLOR_ACCENT'])" Background="#$($p['COLOR_SURFACE'])">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE72E;" FontFamily="$script:KitIconFont" FontSize="15" Foreground="#$($p['COLOR_FG_DIM'])"
                         HorizontalAlignment="Right" VerticalAlignment="Center"/>
              <TextBlock x:Name="Placeholder" Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center" FontStyle="Italic"
                         Foreground="#$($p['COLOR_FG_DIM'])" Text="$(& $x (T 'lock.placeholder'))"/>
              <PasswordBox x:Name="Secret" Grid.Column="1" Margin="6,0,0,0" Background="Transparent" BorderThickness="0"
                           Foreground="#$($p['COLOR_FG'])" CaretBrush="#$($p['COLOR_ACCENT'])" PasswordChar="&#x25CF;" FontSize="16"
                           VerticalContentAlignment="Center"/>
              <Button x:Name="Go" Grid.Column="2" Width="28" Height="28" Focusable="False" Cursor="Hand" HorizontalAlignment="Left">
                <Button.Template><ControlTemplate TargetType="Button">
                  <Grid x:Name="G">
                    <Ellipse Fill="#$($p['COLOR_ACCENT'])"/>
                    <TextBlock Text="&#xE72A;" FontFamily="$script:KitIconFont" FontSize="14" Foreground="#$($p['COLOR_BG'])"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Grid>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="G" Property="Opacity" Value="0.85"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate></Button.Template>
              </Button>
            </Grid>
          </Border>
          <Button x:Name="ModeSwitch" Focusable="False" Cursor="Hand" HorizontalAlignment="Center" Margin="0,10,0,0">
            <Button.Template><ControlTemplate TargetType="Button">
              <TextBlock x:Name="T" Text="{TemplateBinding Content}" FontSize="12" Foreground="#$($p['COLOR_FG_DIM'])" TextDecorations="Underline"/>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Foreground" Value="#$($p['COLOR_ACCENT'])"/></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate></Button.Template>
          </Button>
          <TextBlock x:Name="Caps" Visibility="Collapsed" HorizontalAlignment="Center" Margin="0,10,0,0" FontSize="12" Foreground="#$($p['COLOR_ACCENT'])">
            <Run FontFamily="Segoe UI Symbol" Text="&#x21EA;"/><Run Text=" $(& $x (T 'greeter.caps'))"/>
          </TextBlock>
          <TextBlock x:Name="Status" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0"
                     MinHeight="16" FontSize="12" Foreground="#$($p['COLOR_MUTED'])"/>

          <WrapPanel Margin="0,14,0,0" HorizontalAlignment="Center">
            <Grid Margin="3,0">$(Get-PanelChipXaml $kt 'plain' $theme)</Grid>
            <Grid Margin="3,0">$(Get-PanelChipXaml $kt 'plain' $env:COMPUTERNAME)</Grid>
            <Grid Margin="3,0">$(Get-PanelChipXaml $kt $(if ($online) { 'ok' } else { 'plain' }) $net)</Grid>
          </WrapPanel>
        </StackPanel>
      </Border>
    </StackPanel>

    <Grid VerticalAlignment="Bottom" Margin="28,0,28,24">
      <Border HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="10" Padding="12,8" Background="#D9$($p['COLOR_BG'])">
        $(Get-KitHintsXaml $p $hints)
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="Restart" Style="{StaticResource KitGhost}" Focusable="False" Margin="0,0,10,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE777;" FontFamily="$script:KitIconFont" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="RestartText" Text="$(& $x (T 'greeter.restart'))"/>
          </StackPanel>
        </Button>
        <Button x:Name="Shutdown" Style="{StaticResource KitGhost}" Focusable="False">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7E8;" FontFamily="$script:KitIconFont" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="ShutdownText" Text="$(& $x (T 'greeter.shutdown'))"/>
          </StackPanel>
        </Button>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
"@
}

# A picture for the greeter (the wallpaper, the account's), decoded at the
# width it is shown at; nothing when it cannot be read.
function New-LockPicture([string]$Path, [int]$Width) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $b = New-Object Windows.Media.Imaging.BitmapImage
        $b.BeginInit()
        $b.UriSource = New-Object Uri($Path)
        $b.DecodePixelWidth = $Width
        $b.CacheOption = 'OnLoad'
        $b.EndInit()
        $b.Freeze()
        $b
    } catch { $null }
}

# The picture Windows shows for this account on its own sign-in screen.
function Get-AccountPicturePath {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $k = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -ErrorAction SilentlyContinue
    if (-not $k) { return $null }
    foreach ($n in 'Image448', 'Image240', 'Image192') {
        if ($k.PSObject.Properties[$n] -and (Test-Path -LiteralPath $k.$n)) { return [string]$k.$n }
    }
    $null
}

# -Desktop: the desktop the lock is shown on, 'Default' (the session's own,
# Win+L) or the greeter's (bin\vivac-greeter.ps1): what the secure-screen
# check compares against, and the one left before handing over to Windows'
# own lock. -FirstMode pin|password: what is asked first (the sign-in
# greeter passes the session's own lock mode: the PIN through Windows Hello
# at once, or the password), Tab for the other, and the session's own lock
# mode left alone. Hello's prompt is drawn on the programs' desktop: from a
# desktop of its own the screen goes there for it (-OnHello $true tells the
# caller, whose stage over that desktop steps back) and comes back after
# (-OnHello $false). -PasswordOnly: the account's password is the one way in, no
# Windows Hello (its prompt is a window of Windows' own, drawn on Default:
# over a greeter on its own desktop it would not be seen). -PreviewSeconds:
# unlock by itself after that long (to see the greeter). -OnShown: run once
# the lock has drawn. Returns how it ended: unlocked, ceded (to Windows' own
# lock) or closed.
function Show-VivacLock([switch]$NoShow, [switch]$Greeter, [string]$Desktop = 'Default', [switch]$PasswordOnly, [string]$FirstMode = '', [int]$PreviewSeconds = 0, [scriptblock]$OnShown, [scriptblock]$OnHello) {
    Update-SurfaceContext
    $p = Get-Palette
    $native = Get-LockNative
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $state = @{ Unlocked = $false; Busy = $null; Windows = @(); Armed = $null; ArmedAt = [DateTime]::MinValue; Mode = (Get-VivacLockMode); Outcome = $null; ShownAt = $null; Retaken = 0; OnOwn = ($Desktop -eq 'Default') }
    if ($PasswordOnly) { $state.Mode = 'password' } elseif ($FirstMode) { $state.Mode = $(if ($FirstMode -eq 'pin') { 'pin' } else { 'password' }) }
    # The session's own lock mode is the session's: the sign-in greeter does
    # not decide how Win+L asks next time.
    $keepMode = $PasswordOnly -or [bool]$FirstMode
    $marker = Join-Path (Get-VivacPaths).State 'locked'
    # The host's keyboard hook (lib\VivacKeys.cs) holds the Windows key while
    # the lock is up; the greeter's own process has no hook and needs none
    # (keys on its desktop reach nothing else).
    $keys = 'VivacKeys' -as [type]
    $own = $Desktop -ne 'Default'

    $primaryXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - lock" WindowStyle="None" ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        Background="#$($p['COLOR_BG'])" Cursor="None"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" Foreground="#$($p['COLOR_FG'])">
  <Grid>
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
      <TextBlock x:Name="Clock" HorizontalAlignment="Center" FontSize="112" FontWeight="Bold" Margin="0,0,0,40"/>
      <Border x:Name="Field" Width="322" Height="40" CornerRadius="12" BorderThickness="2"
              BorderBrush="#$($p['COLOR_ACCENT'])" Background="#$($p['COLOR_SURFACE'])">
        <Grid>
          <TextBlock x:Name="Placeholder" HorizontalAlignment="Center" VerticalAlignment="Center" FontStyle="Italic"
                     Foreground="#$($p['COLOR_FG_DIM'])" Text="$(ConvertTo-XmlText (T 'lock.placeholder'))"/>
          <PasswordBox x:Name="Secret" Background="Transparent" BorderThickness="0" Foreground="#$($p['COLOR_FG'])"
                       CaretBrush="#$($p['COLOR_ACCENT'])" PasswordChar="&#x25CF;" FontSize="18"
                       HorizontalContentAlignment="Center" VerticalContentAlignment="Center" Margin="16,0"/>
        </Grid>
      </Border>
      <TextBlock x:Name="Status" HorizontalAlignment="Center" Margin="0,18,0,0" Foreground="#$($p['COLOR_MUTED'])"/>
    </StackPanel>
  </Grid>
</Window>
"@
    # The greeter is dressing: if it cannot be built, the plain lock shows.
    if ($Greeter) {
        try { $primaryXaml = Get-GreeterXaml $p ([bool]$PasswordOnly) } catch { Write-VivacLockLog "greeter not built, plain lock instead: $_"; $Greeter = $false }
    }
    $primary = [Windows.Markup.XamlReader]::Parse($primaryXaml)
    $clock = $primary.FindName('Clock'); $secret = $primary.FindName('Secret')
    $field = $primary.FindName('Field'); $status = $primary.FindName('Status'); $placeholder = $primary.FindName('Placeholder')
    $day = $primary.FindName('Day'); $caps = $primary.FindName('Caps'); $shift = $primary.FindName('CardShift')
    $showTime = {
        $clock.Text = (Get-Date).ToString('HH:mm')
        if ($day) { $d = (Get-Date).ToString('dddd, d MMMM'); $day.Text = $d.Substring(0, 1).ToUpper() + $d.Substring(1) }
        if ($caps) { $caps.Visibility = $(if ([Windows.Input.Keyboard]::IsKeyToggled('CapsLock')) { 'Visible' } else { 'Collapsed' }) }
    }
    & $showTime
    # PIN: the field only says that Enter (or the first digit) brings up
    # Windows Hello, where the PIN is typed. Password: the field takes it.
    $switch = $primary.FindName('ModeSwitch')
    if ($switch -and $PasswordOnly) { $switch.Visibility = 'Collapsed' }
    $reset = $null
    $showMode = {
        $pin = $state.Mode -eq 'pin'
        $secret.Clear()
        $secret.Visibility = $(if ($pin) { 'Collapsed' } else { 'Visible' })
        $placeholder.Text = T $(if ($pin) { 'lock.pin_placeholder' } elseif ($PasswordOnly -or $FirstMode) { 'lock.account_placeholder' } else { 'lock.placeholder' })
        $placeholder.Visibility = 'Visible'
        if ($switch) { $switch.Content = T $(if ($pin) { 'lock.use_password' } else { 'lock.use_pin' }) }
        if ($reset) { & $reset }
        if (-not $pin) { [void]$secret.Focus() }
    }
    & $showMode
    # The greeter's pictures: the theme's wallpaper behind everything, the
    # account's own picture in its circle.
    $backdrop = $null
    if ($Greeter) { try {
        $wall = $null
        try { if (Get-Command Get-VivacWallpaper -ErrorAction SilentlyContinue) { $wall = Get-VivacWallpaper -Theme (Read-VivacTheme $settings['theme']) } } catch { }
        $backdrop = New-LockPicture $wall 1920
        if ($backdrop) { $primary.FindName('Backdrop').Source = $backdrop }
        $face = New-LockPicture (Get-AccountPicturePath) 192
        # Windows' own placeholder (a grey figure on grey) says less than the
        # initial in the accent: any picture without colour is left out.
        if ($face) {
            $px = New-Object Windows.Media.Imaging.FormatConvertedBitmap($face, [Windows.Media.PixelFormats]::Bgra32, $null, 0)
            $bytes = New-Object byte[] ($px.PixelWidth * $px.PixelHeight * 4)
            $px.CopyPixels($bytes, $px.PixelWidth * 4, 0)
            $spread = 0; $n = 0
            for ($i = 0; $i -lt $bytes.Length; $i += 64) {
                $hi = [Math]::Max($bytes[$i], [Math]::Max($bytes[$i + 1], $bytes[$i + 2]))
                $lo = [Math]::Min($bytes[$i], [Math]::Min($bytes[$i + 1], $bytes[$i + 2]))
                $spread += $hi - $lo; $n++
            }
            if ($n -and ($spread / $n) -lt 8) { $face = $null }
        }
        if ($face) {
            $brush = New-Object Windows.Media.ImageBrush($face)
            $brush.Stretch = 'UniformToFill'
            $primary.FindName('Avatar').Fill = $brush
        }
    } catch { Write-VivacLockLog "greeter pictures left out: $_" } }
    # The card fades in when shown; a picture taken without showing it
    # (tests, previews) has it in place already, and so does the greeter on
    # a desktop of its own: its windows are built while that desktop is off
    # screen, where an animation that starts never draws, and the switch to
    # the desktop is the one appearance.
    if ($NoShow -or $own) {
        $card = $primary.FindName('Card')
        if ($card) { $card.Opacity = 1; $shift.Y = 0; $card.Triggers.Clear() }
        if ($NoShow) { return $primary }
    }

    # One window per screen: the clock and the field on the primary one, the
    # base colour on the rest, so no screen shows the desktop.
    $place = { param($w, $screen) Set-VivacScreenWindow $w $screen }
    $windows = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.Primary) { & $place $primary $screen; $windows += $primary; continue }
        $other = New-Object Windows.Window
        $other.WindowStyle = 'None'; $other.ResizeMode = 'NoResize'; $other.Topmost = $true; $other.ShowInTaskbar = $false
        $other.Background = "#$($p['COLOR_BG'])"; $other.Cursor = [Windows.Input.Cursors]::None; $other.Title = 'vivac - lock'
        if ($backdrop) {
            $g = New-Object Windows.Controls.Grid
            $img = New-Object Windows.Controls.Image; $img.Source = $backdrop; $img.Stretch = 'UniformToFill'
            $veil = New-Object Windows.Shapes.Rectangle; $veil.Fill = "#CC$($p['COLOR_BG'])"
            [void]$g.Children.Add($img); [void]$g.Children.Add($veil)
            $other.Content = $g
        }
        & $place $other $screen
        $windows += $other
    }
    $state.Windows = $windows

    # The watchdog: a process of its own, so it outlives this one. It locks
    # the Windows way if the host disappears while vivac's lock is up, and
    # ends by itself once the marker is gone.
    # On the greeter's desktop the process has a watchdog of its own, which
    # also brings the desktop back (bin\vivac-greeter.ps1).
    if (-not $own) {
        Write-VivacFile -Path $marker -Text "$PID`n"
        $watch = "`$m='$marker'; while (Test-Path -LiteralPath `$m) { if (-not (Get-Process -Id $PID -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath `$m -Force; rundll32.exe user32.dll,LockWorkStation; break }; Start-Sleep -Milliseconds 500 }"
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $watch -WindowStyle Hidden | Out-Null
    }

    $finish = {
        $state.Unlocked = $true
        if ($own) { try { [void]$native::SwitchToDefault() } catch { } }
        if ($keys) { $keys::LockMode = $false }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $tick.Stop()
        foreach ($w in $state.Windows) { try { $w.Close() } catch { } }
        foreach ($w in $script:LockCover) { try { $w.Close() } catch { } }
        $script:LockCover = @()
    }
    # Windows' own lock takes over (its secure screen was asked for, Windows
    # Hello cannot be had): the greeter's desktop steps aside first.
    $cede = {
        $state.Outcome = 'ceded'
        if ($own) { try { [void]$native::SwitchToDefault() } catch { } }
        [void]$native::LockWorkStation()
        & $finish
    }
    $fail = {
        param([string]$Message)
        $field.BorderBrush = "#$($p['COLOR_URGENT'])"
        $status.Foreground = "#$($p['COLOR_URGENT'])"
        $status.Text = $Message
        $secret.Clear()
        # The greeter's card shakes its head.
        if ($shift) {
            $no = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $i = 0
            foreach ($v in 0, -12, 10, -8, 6, -3, 0) {
                [void]$no.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame($v, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(55 * $i)))))
                $i++
            }
            $shift.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $no)
        }
    }
    # The greeter's foot carries the keys, so its status line stays empty
    # until there is something to say.
    $idle = { if ($Greeter) { '' } else { T "lock.hint_$($state.Mode)" } }
    $reset = {
        $field.BorderBrush = "#$($p['COLOR_ACCENT'])"
        $status.Foreground = "#$($p['COLOR_MUTED'])"
        $status.Text = & $idle
    }
    & $reset

    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(250)
    $tick.Add_Tick({
            & $showTime
            # A power button pressed once and left alone asks again.
            if ($state.Armed -and ((Get-Date) - $state.ArmedAt).TotalSeconds -gt 4) { & $disarm }
            # A preview has shown enough.
            if ($PreviewSeconds -gt 0 -and $state.ShownAt -and ((Get-Date) - $state.ShownAt).TotalSeconds -ge $PreviewSeconds) {
                Write-VivacLockLog 'preview over'
                & $finish
                return
            }
            # Windows' secure screen took the keyboard (Ctrl+Alt+Del, or its
            # own lock): lock the Windows way and step aside.
            # On a desktop of its own, not before the greeter has switched
            # the screen to it (OnOwn, set once -OnShown has run): until
            # then the programs' desktop is on screen on purpose.
            if (-not $state.Busy -and $state.OnOwn -and -not $native::OnDesktop($Desktop)) {
                $where = $native::InputDesktopName()
                # On a desktop of its own, the screen switched to another
                # desktop of the session (Winlogon settling the sign-in
                # on Default) is taken back; only the secure screen, which
                # cannot be seen, is ceded to.
                if ($own -and $where -eq 'Default' -and $state.Retaken -lt 20 -and $native::SwitchTo($Desktop)) {
                    $state.Retaken++
                    Write-VivacLockLog "the screen had left $Desktop and was taken back ($($state.Retaken))"
                    return
                }
                & $cede
                return
            }
            # A Windows Hello prompt in progress.
            if ($state.Busy) {
                if ($state.Busy.IsCompleted) {
                    $task = $state.Busy; $state.Busy = $null
                    Write-VivacLockLog "Windows Hello answered: $(if ($task.IsFaulted) { 'faulted' } else { [string]$task.Result })"
                    Set-VivacLockTopmost $true $state.Windows
                    if (-not $task.IsFaulted -and [string]$task.Result -eq 'Verified') { if ($state.Mode -eq 'pin' -and -not $keepMode) { Set-VivacLockMode 'pin' }; & $finish; return }
                    if ($task.IsFaulted -or [string]$task.Result -in 'DeviceNotPresent', 'NotConfiguredForUser', 'DisabledByPolicy', 'DeviceBusy') {
                        & $cede; return
                    }
                    # Not verified: the prompt is gone, the greeter's own
                    # desktop comes back on screen and its stage steps up.
                    if ($own) { try { [void]$native::SwitchTo($Desktop) } catch { } }
                    if ($OnHello) { try { & $OnHello $false } catch { } }
                    & $fail (T 'lock.hello_failed')
                    [void]$primary.Activate(); if ($state.Mode -eq 'password') { [void]$secret.Focus() }
                }
                return
            }
            if (-not $primary.IsActive) { Set-VivacForeground $primary; if ($state.Mode -eq 'password') { [void]$secret.Focus() } }
        })

    $secret.Add_PasswordChanged({ $placeholder.Visibility = $(if ($secret.SecurePassword.Length) { 'Hidden' } else { 'Visible' }); if ($secret.SecurePassword.Length) { & $reset } })
    $primary.Add_PreviewKeyDown({
            param($s, $e)
            if ($state.Busy) { return }
            $key = [string]$e.Key
            if ($key -eq 'Escape') { $e.Handled = $true; $secret.Clear(); & $disarm; return }
            if ($key -eq 'Tab') { $e.Handled = $true; if (-not $PasswordOnly) { & $toggle }; return }
            # In PIN mode a digit is the start of the PIN: Windows Hello's
            # prompt opens to take it.
            if ($state.Mode -eq 'pin' -and $key -match '^(D|NumPad)\d$') { $e.Handled = $true; & $hello; return }
            if ($key -ne 'Return') { return }
            $e.Handled = $true
            & $submit
        })
    $go = $primary.FindName('Go')
    if ($go) { $go.Add_Click({ if (-not $state.Busy) { & $submit; if ($state.Mode -eq 'password') { [void]$secret.Focus() } } }) }
    $toggle = {
        & $disarm
        $state.Mode = $(if ($state.Mode -eq 'pin') { 'password' } else { 'pin' })
        if (-not $keepMode) { Set-VivacLockMode $state.Mode }
        & $showMode
        if ($state.Mode -eq 'pin') { & $hello }
    }
    if ($switch) { $switch.Add_Click({ if (-not $state.Busy) { & $toggle } }) }
    $hello = {
        # Windows Hello draws its own prompt, owned by this window: vivac's
        # windows stop being topmost for as long as it is up, so it is seen.
        Set-VivacLockTopmost $false $state.Windows
        $status.Foreground = "#$($p['COLOR_MUTED'])"
        $status.Text = T 'lock.hello_waiting'
        # The prompt is drawn on the programs' desktop: from a desktop of
        # its own the screen goes there, and the prompt is owned by the
        # caller's stage window over that desktop (-OnHello $true gives its
        # handle), so Windows keeps it above the stage while the stage stays
        # topmost: nothing else on that desktop is seen or reached.
        $owner = (New-Object Windows.Interop.WindowInteropHelper $primary).Handle
        if ($own) {
            if ($OnHello) { try { $stage = & $OnHello $true; if ($stage) { $owner = [IntPtr][long]$stage } } catch { } }
            try { [void]$native::SwitchToDefault() } catch { }
        }
        Write-VivacLockLog "Windows Hello asked (input desktop $($native::InputDesktopName()), owner window $owner)"
        # If Windows Hello cannot be asked from here, the PIN still works on
        # Windows' own lock: hand over to it rather than leave the field as
        # the only way in.
        try { $state.Busy = Start-HelloVerification $owner } catch {
            Write-VivacLockLog "Windows Hello not asked, Windows' own lock instead: $_"
            & $cede
        }
    }
    $submit = {
            if ($state.Mode -eq 'pin' -or -not $secret.SecurePassword.Length) {
                if (-not $PasswordOnly) { & $hello }
                return
            }
            $ok = $false
            foreach ($a in (Get-LockAccounts)) {
                if ($native::CheckPassword($a[0], $a[1], $secret.Password)) { $ok = $true; break }
            }
            # The sign-in greeter is always the password: it does not decide
            # how the session's own lock (Win+L) asks next time.
            if ($ok) { if (-not $keepMode) { Set-VivacLockMode 'password' }; & $finish; return }
            # The PIN is not the account's password: Windows only takes it
            # through Windows Hello.
            if (Test-VivacLooksLikePin $secret.Password) { & $fail (T $(if ($PasswordOnly) { 'lock.looks_like_pin_signin' } else { 'lock.looks_like_pin' })) } else { & $fail (T 'lock.wrong') }
        }

    # Restart and shut down: the first press names what the second will do.
    $power = @{
        Restart  = @{ Flag = '/r'; Label = (T 'greeter.restart'); Confirm = (T 'greeter.restart_confirm') }
        Shutdown = @{ Flag = '/s'; Label = (T 'greeter.shutdown'); Confirm = (T 'greeter.shutdown_confirm') }
    }
    # The greeter's buttons carry an icon and a text block named after them;
    # it is the text that changes, and the button takes the accent.
    $label = {
        param($b, [string]$Text)
        $t = $primary.FindName("$($b.Name)Text")
        if ($t) { $t.Text = $Text } else { $b.Content = $Text }
    }
    $disarm = {
        if ($state.Armed) {
            & $label $state.Armed $power[$state.Armed.Name].Label
            $state.Armed.ClearValue([Windows.Controls.Control]::BackgroundProperty)
            $state.Armed.ClearValue([Windows.Controls.Control]::ForegroundProperty)
        }
        $state.Armed = $null
    }
    foreach ($name in $power.Keys) {
        $button = $primary.FindName($name)
        if (-not $button) { continue }
        $button.Add_Click({
                param($b, $e)
                if ($state.Armed -eq $b) {
                    Start-Process shutdown.exe -ArgumentList $power[$b.Name].Flag, '/t', '0' -WindowStyle Hidden
                    return
                }
                & $disarm
                $state.Armed = $b; $state.ArmedAt = Get-Date
                & $label $b $power[$b.Name].Confirm
                $b.Background = "#$($p['COLOR_ACCENT'])"; $b.Foreground = "#$($p['COLOR_BG'])"
                [void]$secret.Focus()
            })
    }
    foreach ($w in $windows) {
        $w.Add_Closing({ param($s, $e) if (-not $state.Unlocked) { $e.Cancel = $true } })
    }
    $primary.Add_ContentRendered({
            $script:LockGreeterUp = $true
            $state.ShownAt = Get-Date
            Write-VivacLockLog "lock on screen (mode $($state.Mode)$(if ($own) { ", desktop $Desktop" }))"
            if ($OnShown) { try { & $OnShown } catch { Write-VivacLockLog "on-shown failed: $_" } }
            $state.OnOwn = $true
            Set-VivacForeground $primary
            # PIN mode asks Windows Hello straight away: nothing to press first.
            if ($state.Mode -eq 'pin') { & $hello } else { [void]$secret.Focus() }
        })

    if ($keys) { $keys::LockMode = $true }
    foreach ($w in $windows) { if ($w -ne $primary) { $w.Show() } }
    $tick.Start()
    try { [void]$primary.ShowDialog() } finally {
        # Whatever ends the dialog, the keyboard is given back and the
        # watchdog told to stand down only after a real unlock.
        if (-not $state.Unlocked) {
            if ($own) { try { [void]$native::SwitchToDefault() } catch { } }
            [void]$native::LockWorkStation()
        }
        if ($keys) { $keys::LockMode = $false }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
    if ($state.Outcome) { $state.Outcome } elseif ($state.Unlocked) { 'unlocked' } else { 'closed' }
}

Export-ModuleMember -Function *
