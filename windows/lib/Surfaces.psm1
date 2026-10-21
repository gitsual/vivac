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
Import-Module (Join-Path $PSScriptRoot 'Phone.psm1')

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
            try { $s.Close() } catch { }
        })
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
        $bodyRow = "<TextBlock Grid.Row=`"2`" Grid.ColumnSpan=`"2`" Margin=`"0,3,0,0`" FontSize=`"12.5`" Foreground=`"#$($p['COLOR_FG'])`" Opacity=`"0.85`" TextWrapping=`"Wrap`" TextTrimming=`"CharacterEllipsis`" MaxHeight=`"68`" Text=`"$(ConvertTo-XmlText $Body)`"/>"
    }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - notification" Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="13">
  <Border x:Name="Card" Background="#F2$($p['COLOR_BG'])" BorderBrush="#$($p['COLOR_SURFACE_ALT'])" BorderThickness="1" CornerRadius="12" Cursor="Hand">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="3"/></Grid.RowDefinitions>
      <Grid Margin="12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Width="48" Height="48" CornerRadius="10" Background="#$($p['COLOR_SURFACE'])" VerticalAlignment="Center" HorizontalAlignment="Left">
          <Grid>
            <TextBlock x:Name="Glyph" Text="$(Get-KitGlyph $Glyph)" FontFamily="$script:KitIconFont" FontSize="20" Foreground="#$($p['COLOR_ACCENT'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Image x:Name="Icon" Width="32" Height="32" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Grid>
        </Border>
        <Grid Grid.Column="1">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock FontSize="11" Foreground="#$($p['COLOR_MUTED'])" TextTrimming="CharacterEllipsis">
            <Run Text="$(ConvertTo-XmlText $App)" Foreground="#$($p['COLOR_ACCENT'])"/><Run Text="  $((Get-Date).ToString('HH:mm'))"/>
          </TextBlock>
          <TextBlock x:Name="Close" Grid.Column="1" Text="$(Get-KitGlyph 0xE711)" FontFamily="$script:KitIconFont" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" Margin="8,1,0,0" Cursor="Hand"/>
          <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Margin="0,4,0,0" FontSize="14" FontWeight="SemiBold" Foreground="#$($p['COLOR_FG'])" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="42" Text="$(ConvertTo-XmlText $Title)"/>
          $bodyRow
        </Grid>
      </Grid>
      <Border x:Name="Progress" Grid.Row="1" Background="#$($p['COLOR_ACCENT'])" HorizontalAlignment="Left" Width="380" CornerRadius="0,0,0,12"/>
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

# The volume indicator that replaces Windows' flyout. The resident host takes
# the volume keys, sets the volume, and shows this; it is built once and
# repainted from the current palette each time, and hides itself after a
# second and a half without a change.
function New-VivacVolumeOsd {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - volume" Width="320" Height="64"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" FontSize="14">
  <Border x:Name="Frame" BorderThickness="2" CornerRadius="12" Padding="16,0">
    <Grid VerticalAlignment="Center">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="34"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Glyph" Grid.Column="0" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="20" VerticalAlignment="Center"/>
      <Border x:Name="Track" Grid.Column="1" Height="8" CornerRadius="4" VerticalAlignment="Center">
        <Border x:Name="Fill" HorizontalAlignment="Left" CornerRadius="4"/>
      </Border>
      <TextBlock x:Name="Level" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center"/>
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
    [pscustomobject]@{ Window = $w; Timer = $hide }
}

function Show-VivacVolumeOsd($Osd, [int]$Level, [bool]$Muted) {
    Update-SurfaceContext
    $p = Get-Palette
    $w = $Osd.Window
    $w.FindName('Frame').Background = "#F2$($p['COLOR_BG'])"
    $w.FindName('Frame').BorderBrush = "#$($p['COLOR_ACCENT'])"
    $w.FindName('Track').Background = "#$($p['COLOR_SURFACE'])"
    $fill = $w.FindName('Fill')
    $fill.Background = "#$($p['COLOR_ACCENT'])"
    if ($Muted) { $fill.Background = "#$($p['COLOR_MUTED'])" }
    $fill.Width = [Math]::Max(0, 200 * $Level / 100)
    $glyph = $w.FindName('Glyph')
    $glyph.Foreground = "#$($p['COLOR_ACCENT'])"
    # Segoe Fluent Icons: mute, then speaker with no, one, two, three waves.
    $glyph.Text = if ($Muted) { [char]0xE74F } elseif ($Level -eq 0) { [char]0xE992 } elseif ($Level -lt 34) { [char]0xE993 } elseif ($Level -lt 67) { [char]0xE994 } else { [char]0xE995 }
    $label = $w.FindName('Level')
    $label.Foreground = "#$($p['COLOR_FG'])"
    $label.Text = "$Level"
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

function Show-Power([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'power' }
    $surfaceName = 'power'
    $p = Get-Palette
    # Segoe Fluent Icons ships with Windows 11; the glyphs are its own.
    $entries = @(
        @{ Id = 'lock'; Glyph = [char]0xE72E; Confirm = $false },
        @{ Id = 'logout'; Glyph = [char]0xF3B1; Confirm = $true },
        @{ Id = 'sleep'; Glyph = [char]0xE708; Confirm = $false },
        @{ Id = 'restart'; Glyph = [char]0xE777; Confirm = $true },
        @{ Id = 'shutdown'; Glyph = [char]0xE7E8; Confirm = $true }
    )
    if (Test-VivacRebootOther) { $entries += @{ Id = 'other'; Glyph = [char]0xE895; Confirm = $true } }
    $buttons = ''
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $buttons += @"
<Border x:Name="B$i" Width="132" Height="150" Margin="8" CornerRadius="10" Background="#$($p['COLOR_SURFACE'])" BorderThickness="0,0,0,3" BorderBrush="#$($p['COLOR_MUTED'])">
  <StackPanel VerticalAlignment="Center">
    <TextBlock HorizontalAlignment="Center" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="40" Foreground="#$($p['COLOR_ACCENT'])" Text="$($e.Glyph)"/>
    <TextBlock x:Name="L$i" HorizontalAlignment="Center" Margin="0,14,0,0" Text="$(ConvertTo-XmlText (T "power.$($e.Id)"))"/>
    <TextBlock HorizontalAlignment="Center" Margin="0,4,0,0" Foreground="#$($p['COLOR_MUTED'])" Text="$($i + 1)"/>
  </StackPanel>
</Border>
"@
    }
    $body = "<StackPanel><StackPanel Orientation='Horizontal' HorizontalAlignment='Center'>$buttons</StackPanel><TextBlock Margin='0,8,0,0' HorizontalAlignment='Center' Foreground='#$($p['COLOR_MUTED'])' Text='$(ConvertTo-XmlText (T 'power.hint'))'/></StackPanel>"
    $window = New-VivacWindow (Get-WindowXaml 'vivac - power' (160 * $entries.Count) 260 $body)
    $state = @{ Index = 0; Armed = -1 }

    $paint = {
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $b = $window.FindName("B$i"); $l = $window.FindName("L$i")
            if ($i -eq $state.Index) { $b.BorderBrush = "#$($p['COLOR_ACCENT'])"; $b.Background = "#$($p['COLOR_SURFACE_ALT'])" }
            else { $b.BorderBrush = "#$($p['COLOR_MUTED'])"; $b.Background = "#$($p['COLOR_SURFACE'])" }
            if ($i -eq $state.Armed) { $l.Text = (T 'power.confirm'); $l.Foreground = "#$($p['COLOR_URGENT'])" }
            else { $l.Text = (T "power.$($entries[$i].Id)"); $l.Foreground = "#$($p['COLOR_FG'])" }
        }
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
        if ($k -eq 'Escape') { $window.Close(); return }
        if ($k -eq 'Left' -and $state.Index -gt 0) { $state.Index--; $state.Armed = -1; & $paint; return }
        if ($k -eq 'Right' -and $state.Index -lt $entries.Count - 1) { $state.Index++; $state.Armed = -1; & $paint; return }
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
    $current = $settings['theme']
    $names = @(Get-VivacCatalogue)
    $body = @"
<DockPanel>
  <TextBlock DockPanel.Dock="Top" Margin="0,0,0,12" FontSize="16" Foreground="#$($p['COLOR_ACCENT'])" Text="$(ConvertTo-XmlText (T 'theme.title'))"/>
  <TextBlock DockPanel.Dock="Bottom" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#$($p['COLOR_MUTED'])" Text="$(ConvertTo-XmlText (T 'theme.hint'))"/>
  <ListBox x:Name="Rows" Background="Transparent" BorderThickness="0" Foreground="#$($p['COLOR_FG'])">
    <ListBox.Resources>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#$($p['COLOR_SURFACE_ALT'])"/>
      <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#$($p['COLOR_FG'])"/>
    </ListBox.Resources>
  </ListBox>
</DockPanel>
"@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - theme' 640 520 $body)
    $rows = $window.FindName('Rows')
    foreach ($name in $names) {
        $t = Read-VivacTheme $name
        $panel = New-Object Windows.Controls.StackPanel
        $panel.Orientation = 'Horizontal'
        $panel.Margin = '4,6'
        $panel.Tag = $name
        foreach ($tok in 'COLOR_BG', 'COLOR_SURFACE', 'COLOR_SURFACE_ALT', 'COLOR_ACCENT', 'COLOR_MUTED', 'COLOR_INFO', 'COLOR_OK', 'COLOR_FG') {
            $sw = New-Object Windows.Shapes.Rectangle
            $sw.Width = 18; $sw.Height = 18; $sw.RadiusX = 4; $sw.RadiusY = 4; $sw.Margin = '0,0,3,0'
            $sw.Fill = "#$($t.Tokens[$tok])"
            [void]$panel.Children.Add($sw)
        }
        $label = New-Object Windows.Controls.TextBlock
        $label.Margin = '14,0,0,0'
        $label.VerticalAlignment = 'Center'
        $mark = '  '
        if ($name -eq $current) { $mark = '* ' }
        $label.Text = "$mark$($t.Title)  -  $($t.Essence)"
        [void]$panel.Children.Add($label)
        [void]$rows.Items.Add($panel)
    }
    $rows.SelectedIndex = [Math]::Max(0, [array]::IndexOf($names, $current))

    $apply = {
        $sel = $rows.SelectedItem
        if (-not $sel) { return }
        $window.Close()
        # Applied in the background: a theme switch restarts the bar and may
        # render a wallpaper, and the picker should not sit on screen for it.
        Invoke-Detached (Join-Path $root 'scripts\apply-theme.ps1') @('-Theme', [string]$sel.Tag)
    }
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { $window.Close(); return }
        if ($k -eq 'Return') { & $apply; $e.Handled = $true; return }
    })
    $rows.Add_MouseDoubleClick({ & $apply })
    $window.Add_ContentRendered({ $rows.Focus() | Out-Null; $rows.ScrollIntoView($rows.SelectedItem) })
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
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
    # The phone, a category of its own while KDE Connect is installed
    # (lib/Phone.psm1); read from what the bar last saw, never asked here.
    foreach ($p in @(Get-VivacPhoneMenuEntries ${function:New-MenuEntry})) { $e.Add($p) }
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
    $hints = Get-KitHintsXaml $p @(@('&#x2191;&#x2193;', (T 'menu.key.move')), @('Tab', (T 'menu.key.category')), @('&#x21B5;', (T 'menu.key.open')),
        @('Ctrl+&#x21B5;', (T 'menu.key.admin')), @('Esc', (T 'menu.key.close')))
    $icon = $script:KitIconFont
    @"
<Grid>
  <Grid.Resources>
$(Get-KitResourcesXaml $p)
  </Grid.Resources>
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="210"/>
    <ColumnDefinition Width="18"/>
    <ColumnDefinition Width="*"/>
  </Grid.ColumnDefinitions>

  <DockPanel Grid.Column="0">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,0,0,16">
      <Border Width="40" Height="40" CornerRadius="20" Background="#$($p['COLOR_ACCENT'])">
        <TextBlock x:Name="Initial" FontSize="18" FontWeight="Bold" Foreground="#$($p['COLOR_BG'])" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="User" FontSize="15" FontWeight="SemiBold" Foreground="#$($p['COLOR_FG'])"/>
        <TextBlock x:Name="Today" FontSize="11" Foreground="#$($p['COLOR_MUTED'])"/>
      </StackPanel>
    </StackPanel>
    <Grid x:Name="Power" DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
    </Grid>
    <ListBox x:Name="Cats" Background="Transparent" BorderThickness="0" Focusable="False"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemTemplate><DataTemplate>
        <Grid Height="38">
          <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="{Binding Glyph}" FontFamily="$icon" FontSize="15" Foreground="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="1" Text="{Binding Name}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          <TextBlock Grid.Column="2" Text="{Binding Sub}" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" VerticalAlignment="Center" Margin="6,0,2,0"/>
        </Grid>
      </DataTemplate></ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>

  <Border Grid.Column="1" Width="1" HorizontalAlignment="Center" Background="#$($p['COLOR_SURFACE_ALT'])"/>

  <DockPanel Grid.Column="2">
    <Border DockPanel.Dock="Top" Background="#$($p['COLOR_SURFACE'])" CornerRadius="10" Padding="14,10" Margin="0,0,0,12"
            BorderBrush="#$($p['COLOR_ACCENT'])" BorderThickness="1">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#xE721;" FontFamily="$icon" FontSize="16" Foreground="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <TextBlock x:Name="Placeholder" Grid.Column="1" FontSize="16" Foreground="#$($p['COLOR_MUTED'])" VerticalAlignment="Center" IsHitTestVisible="False"
                   Text="$(ConvertTo-XmlText (T 'menu.placeholder'))"/>
        <TextBox x:Name="Filter" Grid.Column="1" FontSize="16" Background="Transparent" BorderThickness="0" Padding="0"
                 Foreground="#$($p['COLOR_FG'])" CaretBrush="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center"/>
        <TextBlock x:Name="Count" Grid.Column="2" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" VerticalAlignment="Center" Margin="12,0,0,0"/>
      </Grid>
    </Border>
    <Border DockPanel.Dock="Bottom" Margin="2,12,0,0">$hints</Border>
    <ListBox x:Name="Rows" Background="Transparent" BorderThickness="0" Focusable="False"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True"
             VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.IsVirtualizingWhenGrouping="True"
             VirtualizingPanel.VirtualizationMode="Recycling" VirtualizingPanel.ScrollUnit="Pixel">
      <ListBox.GroupStyle>
        <GroupStyle>
          <GroupStyle.HeaderTemplate><DataTemplate>
            <TextBlock Text="{Binding Name}" FontSize="11" FontWeight="SemiBold" Foreground="#$($p['COLOR_ACCENT'])" Margin="10,10,0,4"/>
          </DataTemplate></GroupStyle.HeaderTemplate>
        </GroupStyle>
      </ListBox.GroupStyle>
      <ListBox.ItemTemplate><DataTemplate>
        <Grid Height="48">
          <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border Width="36" Height="36" CornerRadius="9" Background="#$($p['COLOR_SURFACE'])">
            <Grid>
              <TextBlock Text="{Binding Glyph}" FontFamily="$icon" FontSize="17" Foreground="#$($p['COLOR_ACCENT'])"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="{Binding ShowGlyph, Converter={StaticResource B2V}}"/>
              <Image Source="{Binding Icon}" Width="26" Height="26" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Grid>
          </Border>
          <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="12,0,8,0">
            <TextBlock x:Name="N" Text="{Binding Name}" FontSize="14" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Sub}" FontSize="11" Foreground="#$($p['COLOR_MUTED'])" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <Border x:Name="Go" Grid.Column="2" Background="#$($p['COLOR_ACCENT'])" CornerRadius="4" Padding="7,1" Margin="0,0,6,0"
                  VerticalAlignment="Center" Visibility="Hidden">
            <TextBlock Text="&#x21B5;" FontSize="12" Foreground="#$($p['COLOR_BG'])"/>
          </Border>
        </Grid>
        <DataTemplate.Triggers>
          <DataTrigger Binding="{Binding Urgent}" Value="True"><Setter TargetName="N" Property="Foreground" Value="#$($p['COLOR_URGENT'])"/></DataTrigger>
          <DataTrigger Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="True">
            <Setter TargetName="Go" Property="Visibility" Value="Visible"/>
          </DataTrigger>
        </DataTemplate.Triggers>
      </DataTemplate></ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Grid>
"@
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

    $window = New-VivacWindow (Get-WindowXaml 'vivac - menu' 1000 640 (Get-MenuXaml $p))
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
        $b.Height = 38; $b.Margin = '2,0'; $b.CornerRadius = 8; $b.Cursor = 'Hand'
        $b.Background = "#$($p['COLOR_SURFACE'])"
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
        $b.Add_MouseLeave({ param($s) $s.Background = "#$($p['COLOR_SURFACE'])" })
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

function Show-Sound([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'sound' }
    $surfaceName = 'sound'
    Import-VivacAudio
    try { Import-VivacMenu } catch { }
    $p = Get-Palette
    $body = @"
<StackPanel>
  <Border Style="{StaticResource KitCard}" Margin="0,0,0,14">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="MasterGlyph" FontFamily="$script:KitIconFont" FontSize="20" Foreground="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center" Cursor="Hand" Margin="0,0,12,0"/>
      <Slider x:Name="Master" Grid.Column="1" VerticalAlignment="Center"/>
      <TextBlock x:Name="MasterValue" Grid.Column="2" FontSize="22" FontWeight="SemiBold" Foreground="#$($p['COLOR_FG'])" VerticalAlignment="Center" Margin="14,0,0,0" MinWidth="58" TextAlignment="Right"/>
    </Grid>
  </Border>
  <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel x:Name="Sections"/>
  </ScrollViewer>
  <Button x:Name="More" Style="{StaticResource KitGhost}" Margin="0,12,0,0" HorizontalAlignment="Stretch">
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="&#xE713;" FontFamily="$script:KitIconFont" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock Text="$(ConvertTo-XmlText (T 'sound.more'))" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</StackPanel>
"@
    $hints = @(@((T 'sound.key.click'), (T 'sound.key.default')), @((T 'sound.key.icon'), (T 'sound.key.mute')), @('Esc', (T 'sound.key.close')))
    $window = New-VivacWindow (Get-WindowXaml 'vivac - sound' 460 600 (Get-KitPanelXaml $p 0xE767 (T 'sound.title') $body $hints))
    Set-KitDropDown $window
    $sections = $window.FindName('Sections')
    $subtitle = $window.FindName('Subtitle')
    $master = $window.FindName('Master')
    $masterValue = $window.FindName('MasterValue')
    $masterGlyph = $window.FindName('MasterGlyph')
    $window.FindName('More').Add_Click({ $window.Close(); Start-Process 'ms-settings:sound' })
    # The list scrolls; the window stops short of the screen's bottom.
    $window.FindName('Scroll').MaxHeight = [Math]::Max(200, $window.MaxHeight - 300)

    # What the rows and the master control share: the default output, its
    # slider row and the mute switch in the header.
    $state = @{ DefaultId = $null; DefaultSlider = $null; Syncing = $false; Switch = $null }

    $glyphFor = {
        param([bool]$Muted, [bool]$Mic)
        if ($Mic) { if ($Muted) { [string][char]0xF781 } else { [string][char]0xE720 } }
        elseif ($Muted) { [string][char]0xE74F } else { [string][char]0xE767 }
    }
    # The kind of device, from its name, as Windows does not say it plainly.
    $deviceGlyph = {
        param([string]$Name, [bool]$Mic)
        if ($Mic) { return 0xE720 }
        if ($Name -match 'Auricular|Headphone|Headset|Cascos') { return 0xE7F6 }
        if ($Name -match 'HDMI|NVIDIA|Display|DisplayPort|Monitor|\bVA\d|TV') { return 0xE7F4 }
        if ($Name -match 'Digital|S/PDIF|SPDIF|Optical') { return 0xE8D6 }
        0xE7F5
    }

    $newText = {
        param([string]$Text, [string]$Color, [double]$Size = 14)
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text; $t.Foreground = "#$Color"; $t.FontSize = $Size
        $t.VerticalAlignment = 'Center'
        $t
    }
    $newHeader = {
        param([string]$Text)
        $t = & $newText $Text.ToUpper() $p['COLOR_ACCENT'] 11
        $t.FontWeight = 'SemiBold'; $t.Margin = '10,10,0,6'
        $t
    }

    # One control line: a mute glyph, a slider and the number. $Apply gets
    # (tag, level) and $Mute gets (tag, muted); the tag says what they act on.
    $newLevelRow = {
        param($Tag, [int]$Level, [bool]$Muted, [bool]$Mic, [scriptblock]$Apply, [scriptblock]$Mute)
        $g = New-Object Windows.Controls.Grid
        $g.Margin = '44,2,0,4'
        foreach ($w in 28, 0, 46) {
            $c = New-Object Windows.Controls.ColumnDefinition
            if ($w) { $c.Width = $w } else { $c.Width = '*' }
            $g.ColumnDefinitions.Add($c)
        }
        $glyph = & $newText (& $glyphFor $Muted $Mic) $p['COLOR_ACCENT'] 15
        $glyph.FontFamily = $script:KitIconFont
        $glyph.Cursor = 'Hand'
        $glyph.ToolTip = T 'sound.key.mute'
        if ($Muted) { $glyph.Foreground = "#$($p['COLOR_MUTED'])" }
        # What a handler needs travels in the control's Tag: the handlers run long
        # after this block has returned, when its variables are gone.
        $glyph.Tag = @{ Tag = $Tag; Muted = $Muted; Mic = $Mic; Mute = $Mute }
        $glyph.Add_MouseLeftButtonUp({
                param($s, $e)
                $s.Tag.Muted = -not $s.Tag.Muted
                & $s.Tag.Mute $s.Tag.Tag $s.Tag.Muted
                $s.Text = & $glyphFor $s.Tag.Muted $s.Tag.Mic
                if ($s.Tag.Muted) { $s.Foreground = "#$($p['COLOR_MUTED'])" } else { $s.Foreground = "#$($p['COLOR_ACCENT'])" }
                if ([string]$s.Tag.Tag -eq [string]$state.DefaultId) { & $syncHeader }
                $e.Handled = $true
            })
        [Windows.Controls.Grid]::SetColumn($glyph, 0)
        $slider = New-Object Windows.Controls.Slider
        # The range before the value: a Slider starts at 0..10 and would clamp it.
        $slider.Minimum = 0
        $slider.Maximum = 100
        $slider.Value = $Level
        $slider.VerticalAlignment = 'Center'
        $value = & $newText "$Level%" $p['COLOR_FG_DIM'] 12
        $value.HorizontalAlignment = 'Right'
        $slider.Tag = @{ Tag = $Tag; Label = $value; Apply = $Apply }
        $slider.Add_ValueChanged({
                param($s)
                $level = [int][Math]::Round($s.Value)
                $s.Tag.Label.Text = "$level%"
                & $s.Tag.Apply $s.Tag.Tag $level
                if (-not $state.Syncing -and [string]$s.Tag.Tag -eq [string]$state.DefaultId) {
                    $state.Syncing = $true
                    try { $master.Value = $level } finally { $state.Syncing = $false }
                    & $syncHeader
                }
            })
        [Windows.Controls.Grid]::SetColumn($slider, 1)
        [Windows.Controls.Grid]::SetColumn($value, 2)
        [void]$g.Children.Add($glyph); [void]$g.Children.Add($slider); [void]$g.Children.Add($value)
        $g.Tag = $slider
        $g
    }

    # A block that lights up under the pointer, as the menu's rows do; the
    # default device keeps the selected look with the accent bar.
    $newBlock = {
        param([bool]$Selected)
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = 10; $b.Padding = '10,6'; $b.Margin = '0,0,0,6'
        $bg = $p['COLOR_SURFACE']
        if ($Selected) { $bg = $p['COLOR_SURFACE_ALT'] }
        $b.Background = "#$bg"
        $b.Tag = $bg
        $b.Add_MouseEnter({ param($s) if ($s.Tag -ne $p['COLOR_SURFACE_ALT']) { $s.Background = "#$($p['COLOR_SURFACE_ALT'])" } })
        $b.Add_MouseLeave({ param($s) $s.Background = "#$($s.Tag)" })
        $b
    }

    # The header: the default output's name, its level in large type and
    # its mute switch.
    $syncHeader = {
        $id = $state.DefaultId
        if (-not $id) { $subtitle.Text = T 'sound.none'; return }
        $muted = $false
        try { $muted = [VivacAudio]::GetMute() } catch { }
        $level = [int][Math]::Round($master.Value)
        if ($muted) { $masterValue.Text = T 'sound.muted_short'; $masterValue.Foreground = "#$($p['COLOR_MUTED'])" }
        else { $masterValue.Text = "$level%"; $masterValue.Foreground = "#$($p['COLOR_FG'])" }
        $masterGlyph.Text = & $glyphFor $muted $false
        if ($muted) { $masterGlyph.Foreground = "#$($p['COLOR_MUTED'])" } else { $masterGlyph.Foreground = "#$($p['COLOR_ACCENT'])" }
        if ($state.Switch) {
            $state.Syncing = $true
            try { $state.Switch.IsChecked = -not $muted } finally { $state.Syncing = $false }
        }
    }

    $master.Add_ValueChanged({
            param($s)
            if ($state.Syncing -or -not $state.DefaultId) { return }
            $level = [int][Math]::Round($s.Value)
            $state.Syncing = $true
            try {
                if ($state.DefaultSlider) { $state.DefaultSlider.Value = $level } else { [VivacAudio]::SetVolume($state.DefaultId, $level) }
            } finally { $state.Syncing = $false }
            & $syncHeader
        })
    $toggleMaster = {
        if (-not $state.DefaultId) { return }
        try { [void][VivacAudio]::ToggleMute() } catch { }
        & $render
    }
    $masterGlyph.Add_MouseLeftButtonUp({ & $toggleMaster })

    $sw = New-Object Windows.Controls.Primitives.ToggleButton
    $sw.Style = $window.FindName('HeaderRight').FindResource('KitSwitch')
    $sw.ToolTip = T 'sound.key.mute'
    $state.Switch = $sw
    $sw.Add_Click({ if (-not $state.Syncing) { & $toggleMaster } })
    [void]$window.FindName('HeaderRight').Children.Add($sw)

    $render = {
        $sections.Children.Clear()
        $state.DefaultId = $null; $state.DefaultSlider = $null
        foreach ($flow in 0, 1) {
            [void]$sections.Children.Add((& $newHeader (T @('sound.output', 'sound.input')[$flow])))
            $devices = @([VivacAudio]::Devices($flow))
            if (-not $devices.Count) {
                $none = & $newText (T 'sound.none') $p['COLOR_MUTED'] 12
                $none.Margin = '10,0,0,6'
                [void]$sections.Children.Add($none)
            }
            foreach ($d in $devices) {
                $box = & $newBlock $d.IsDefault
                $stack = New-Object Windows.Controls.StackPanel
                $check = $null
                $sub = T 'sound.use'
                if ($d.IsDefault) {
                    $sub = T 'sound.default'
                    $check = & $newText ([string][char]0xE73E) $p['COLOR_ACCENT'] 14
                    $check.FontFamily = $script:KitIconFont
                    $check.Margin = '0,0,4,0'
                }
                $row = New-KitRow $p (& $deviceGlyph $d.Name ($flow -eq 1)) $d.Name $sub $check
                $row.Cursor = 'Hand'
                if ($d.IsDefault) { $row.Tag.Name.FontWeight = 'SemiBold' }
                # Clicking the device makes it the default one.
                $row.Tag['Id'] = $d.Id
                $row.Add_MouseLeftButtonUp({ param($s) try { [VivacAudio]::SetDefault([string]$s.Tag['Id']) } catch { }; & $render })
                [void]$stack.Children.Add($row)
                $level = & $newLevelRow $d.Id $d.Volume $d.Muted ($flow -eq 1) { param($id, $l) [VivacAudio]::SetVolume($id, $l) } { param($id, $m) [VivacAudio]::SetMute($id, $m) }
                [void]$stack.Children.Add($level)
                $box.Child = $stack
                [void]$sections.Children.Add($box)
                if ($flow -eq 0 -and $d.IsDefault) {
                    $state.DefaultId = $d.Id
                    $state.DefaultSlider = $level.Tag
                    $subtitle.Text = $d.Name
                    $state.Syncing = $true
                    try { $master.Value = $d.Volume } finally { $state.Syncing = $false }
                }
            }
        }
        [void]$sections.Children.Add((& $newHeader (T 'sound.apps')))
        # An application can hold several sessions (one per stream); they are
        # one row, and the row moves them all. Its icon is its program's.
        $groups = @([VivacAudio]::Sessions((T 'sound.system_sounds')) | Group-Object Name)
        if (-not $groups.Count) {
            $none = & $newText (T 'sound.no_apps') $p['COLOR_MUTED'] 12
            $none.Margin = '10,0,0,6'
            [void]$sections.Children.Add($none)
        }
        foreach ($grp in $groups) {
            $first = $grp.Group[0]
            $box = & $newBlock $false
            $stack = New-Object Windows.Controls.StackPanel
            $name = $grp.Name
            $exe = $null
            if ($first.ProcessId) {
                try {
                    $proc = Get-Process -Id ([int]$first.ProcessId) -ErrorAction Stop
                    $exe = $proc.Path
                    $desc = $proc.MainModule.FileVersionInfo.FileDescription
                    if ($desc -and $name -eq $proc.ProcessName) { $name = $desc }
                } catch { }
            }
            $glyphCode = 0xE8D6
            if ($name -eq (T 'sound.system_sounds')) { $glyphCode = 0xEA8F }
            $row = New-KitRow $p $glyphCode $name (T 'sound.app_sub' @([string]$grp.Count))
            if ($grp.Count -le 1) { $row.Tag.Sub.Visibility = 'Collapsed' }
            if ($exe -and ('VivacMenuRow' -as [type])) {
                # The program's own icon, through a binding: it arrives on the
                # icon thread (lib/VivacMenu.cs) and the row shows it then, the
                # glyph standing in until it does.
                $iconRow = New-Object VivacMenuRow
                $iconRow.IconKey = $exe
                $grid = New-Object Windows.Controls.Grid
                $glyphText = $row.Tag.Glyph
                $row.Tag.Tile.Child = $null
                $vis = New-Object Windows.Data.Binding 'ShowGlyph'
                $vis.Source = $iconRow
                $vis.Converter = New-Object Windows.Controls.BooleanToVisibilityConverter
                [void]$glyphText.SetBinding([Windows.UIElement]::VisibilityProperty, $vis)
                $img = New-Object Windows.Controls.Image
                $img.Width = 24; $img.Height = 24
                [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
                $src = New-Object Windows.Data.Binding 'Icon'
                $src.Source = $iconRow
                [void]$img.SetBinding([Windows.Controls.Image]::SourceProperty, $src)
                [void]$grid.Children.Add($glyphText); [void]$grid.Children.Add($img)
                $row.Tag.Tile.Child = $grid
            }
            [void]$stack.Children.Add($row)
            $indexes = @($grp.Group | ForEach-Object { $_.Index })
            [void]$stack.Children.Add((& $newLevelRow $indexes $first.Volume $first.Muted $false { param($ix, $l) foreach ($i in $ix) { [VivacAudio]::SetSessionVolume($i, $l) } } { param($ix, $m) foreach ($i in $ix) { [VivacAudio]::SetSessionMute($i, $m) } }))
            $box.Child = $stack
            [void]$sections.Children.Add($box)
        }
        & $syncHeader
    }

    $window.Add_PreviewKeyDown({ param($s, $e) if ([string]$e.Key -eq 'Escape') { $window.Close(); $e.Handled = $true } })
    & $render
    if ($NoShow) { return $window }
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
        $entry = [pscustomobject]@{ Kind = 'text'; Text = $text; Image = $null; Key = $text }
    } elseif ([Windows.Clipboard]::ContainsImage()) {
        $img = [Windows.Clipboard]::GetImage()
        if (-not $img) { return }
        $img.Freeze()
        $entry = [pscustomobject]@{ Kind = 'image'; Text = ''; Image = $img; Key = "image:$($img.PixelWidth)x$($img.PixelHeight):$($img.GetHashCode())" }
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
function Show-Clipboard([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'clipboard' }
    $surfaceName = 'clipboard'
    $p = Get-Palette
    $native = Get-PasteNative
    $previous = $native::GetForegroundWindow()
    $body = @"
<DockPanel>
  <TextBox x:Name="Filter" DockPanel.Dock="Top" Margin="0,0,0,10" Padding="8,6" FontSize="16" Background="#$($p['COLOR_SURFACE'])"
           Foreground="#$($p['COLOR_FG'])" CaretBrush="#$($p['COLOR_ACCENT'])" BorderBrush="#$($p['COLOR_ACCENT'])" BorderThickness="0,0,0,2"/>
  <TextBlock DockPanel.Dock="Bottom" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#$($p['COLOR_MUTED'])" Text="$(ConvertTo-XmlText (T 'clip.hint'))"/>
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
    $window = New-VivacWindow (Get-WindowXaml 'vivac - clipboard' 760 560 $body)
    $rows = $window.FindName('Rows')
    $filter = $window.FindName('Filter')

    $render = {
        $rows.Items.Clear()
        $needle = (ConvertTo-MenuKey $filter.Text.Trim())
        foreach ($e in $script:ClipHistory) {
            if ($needle -and ($e.Kind -ne 'text' -or (ConvertTo-MenuKey $e.Text).IndexOf($needle) -lt 0)) { continue }
            $item = New-Object Windows.Controls.StackPanel
            $item.Orientation = 'Horizontal'
            $item.Margin = '4,4'
            $item.Tag = $e
            if ($e.Kind -eq 'image') {
                $img = New-Object Windows.Controls.Image
                $img.Source = $e.Image; $img.Height = 48; $img.MaxWidth = 160; $img.Stretch = 'Uniform'
                [void]$item.Children.Add($img)
                $label = New-Object Windows.Controls.TextBlock
                $label.Margin = '12,0,0,0'; $label.VerticalAlignment = 'Center'; $label.Foreground = "#$($p['COLOR_MUTED'])"
                $label.Text = T 'clip.image' @($e.Image.PixelWidth, $e.Image.PixelHeight)
                [void]$item.Children.Add($label)
            } else {
                $lines = @($e.Text -split "`r?`n")
                $first = $lines[0].Trim()
                if ($first.Length -gt 90) { $first = $first.Substring(0, 89) + [char]0x2026 }
                $t = New-Object Windows.Controls.TextBlock
                $t.Text = $first
                [void]$item.Children.Add($t)
                if ($lines.Count -gt 1) {
                    $more = New-Object Windows.Controls.TextBlock
                    $more.Margin = '10,0,0,0'; $more.Foreground = "#$($p['COLOR_MUTED'])"
                    $more.Text = T 'clip.lines' @($lines.Count - 1)
                    [void]$item.Children.Add($more)
                }
            }
            [void]$rows.Items.Add($item)
        }
        if (-not $rows.Items.Count) {
            $empty = New-Object Windows.Controls.TextBlock
            $empty.Foreground = "#$($p['COLOR_MUTED'])"; $empty.Margin = '6,6'
            $empty.Text = T 'clip.empty'
            [void]$rows.Items.Add($empty)
        } else { $rows.SelectedIndex = 0 }
    }

    $paste = {
        $sel = $rows.SelectedItem
        if (-not $sel -or -not $sel.Tag) { return }
        $e = $sel.Tag
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

    $filter.Add_TextChanged({ & $render })
    $window.Add_PreviewKeyDown({
        param($s, $ev)
        $k = [string]$ev.Key
        if ($k -eq 'Escape') { $window.Close(); $ev.Handled = $true; return }
        if ($k -eq 'Down' -and $rows.SelectedIndex -lt $rows.Items.Count - 1) { $rows.SelectedIndex++; $rows.ScrollIntoView($rows.SelectedItem); $ev.Handled = $true; return }
        if ($k -eq 'Up' -and $rows.SelectedIndex -gt 0) { $rows.SelectedIndex--; $rows.ScrollIntoView($rows.SelectedItem); $ev.Handled = $true; return }
        if ($k -eq 'Return') { & $paste; $ev.Handled = $true; return }
        if ($k -eq 'Delete') {
            if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) { $script:ClipHistory.Clear() }
            elseif ($rows.SelectedItem -and $rows.SelectedItem.Tag) { [void]$script:ClipHistory.Remove($rows.SelectedItem.Tag) }
            & $render; $ev.Handled = $true; return
        }
    })
    $rows.Add_MouseDoubleClick({ & $paste })
    $window.Add_ContentRendered({ $filter.Focus() | Out-Null })
    & $render
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
        try { Invoke-VivacWithLockMarker 'lock' { Show-VivacLock -Greeter:$Greeter } } finally { $script:LockShown = $false }
        return
    }
    # Windows' own lock takes over: the cover must not stay behind it, or the
    # desktop is hidden after the unlock.
    Hide-VivacLockCover
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
    // The desktop that has the keyboard: "Default" while the user's own
    // session shows; anything else (or no access at all) means Windows'
    // secure screen -- Ctrl+Alt+Del, its lock, a UAC prompt -- has it.
    public static bool OnUserDesktop() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001);
        if (d == IntPtr.Zero) return false;
        try {
            StringBuilder name = new StringBuilder(64); int needed;
            if (!GetUserObjectInformation(d, 2, name, name.Capacity * 2, out needed)) return false;
            return string.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
        } finally { CloseDesktop(d); }
    }
}
'@
    }
    [VivacLockNative]
}

function Start-HelloVerification {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $op = [Windows.Security.Credentials.UI.UserConsentVerifier]::RequestVerificationAsync((T 'lock.hello_message'))
    $asTask.MakeGenericMethod([Windows.Security.Credentials.UI.UserConsentVerificationResult]).Invoke($null, @($op))
}

# At sign-in (bin\vivac-daemon.ps1 -LockAtStart, after an automatic Windows
# sign-in) the screens are covered in the theme's base colour the moment the
# host starts, before it has built anything else; vivac's lock then opens on
# top, and the cover goes away with it on unlock.
$script:LockCover = @()
function Show-VivacLockCover {
    Update-SurfaceContext
    $p = Get-Palette
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96.0; $g.Dispose()
    $script:LockCover = @(foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $w = New-Object Windows.Window
            $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.Topmost = $true; $w.ShowInTaskbar = $false
            $w.Background = "#$($p['COLOR_BG'])"; $w.Cursor = [Windows.Input.Cursors]::None; $w.Title = 'vivac - lock'
            $w.WindowStartupLocation = 'Manual'
            $b = $screen.Bounds
            $w.Left = $b.Left / $scale; $w.Top = $b.Top / $scale; $w.Width = $b.Width / $scale; $w.Height = $b.Height / $scale
            $w.Show()
            $w
        })
}
# Drops the cover without unlocking: when the lock itself could not be shown,
# the desktop must not stay hidden behind blank windows.
function Hide-VivacLockCover {
    foreach ($w in $script:LockCover) { try { $w.Close() } catch { } }
    $script:LockCover = @()
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
function Get-GreeterXaml($p) {
    $name = $env:USERNAME
    try { $full = [string](Get-LocalUser -Name $env:USERNAME -ErrorAction Stop).FullName; if ($full) { $name = $full } } catch { }
    $account = [string](@(Get-LockAccounts | ForEach-Object { $_[0] } | Where-Object { $_ -match '@' }) + '')[0]
    $hour = (Get-Date).Hour
    $greeting = T $(if ($hour -ge 6 -and $hour -lt 14) { 'greeter.morning' } elseif ($hour -ge 14 -and $hour -lt 21) { 'greeter.afternoon' } else { 'greeter.evening' })
    $theme = [string]$settings['theme']
    try { $theme = [string](Read-VivacTheme $settings['theme']).Title } catch { }
    if (-not $theme) { $theme = [string]$settings['theme'] }
    $online = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $net = T $(if ($online) { 'greeter.online' } else { 'greeter.offline' })
    $netColor = $(if ($online) { $p['COLOR_INFO'] } else { $p['COLOR_MUTED'] })
    $accountVis = $(if ($account) { 'Visible' } else { 'Collapsed' })
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

    <!-- The bar's strip, as the desktop will have it. -->
    <Border VerticalAlignment="Top" Margin="16,12,16,0" Height="38" CornerRadius="12" Padding="16,0"
            Background="#D9$($p['COLOR_BG'])" BorderThickness="0,0,0,3" BorderBrush="#$($p['COLOR_ACCENT'])">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="vivac" FontWeight="Bold" Foreground="#$($p['COLOR_ACCENT'])"/>
          <TextBlock Text="  $(& $x $theme)" Foreground="#$($p['COLOR_FG_DIM'])"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock Text="&#xE774;" FontFamily="$script:KitIconFont" FontSize="13" Foreground="#$netColor" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock Text="$(& $x $env:COMPUTERNAME)" Foreground="#$($p['COLOR_FG_DIM'])" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>

    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,24">
      <TextBlock x:Name="Clock" HorizontalAlignment="Center" FontSize="104" FontWeight="Light"/>
      <TextBlock x:Name="Day" HorizontalAlignment="Center" FontSize="17" Foreground="#$($p['COLOR_FG_DIM'])" Margin="0,0,0,34"/>

      <Border x:Name="Card" Width="420" CornerRadius="16" Padding="28,26,28,22" Opacity="0"
              Background="#F0$($p['COLOR_BG'])" BorderThickness="0,0,0,3" BorderBrush="#$($p['COLOR_ACCENT'])">
        <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="10" Opacity="0.45" Color="#000000"/></Border.Effect>
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
          <Grid Width="92" Height="92" HorizontalAlignment="Center">
            <Ellipse Fill="#$($p['COLOR_ACCENT'])"/>
            <TextBlock Text="$(& $x $name.Substring(0, 1).ToUpper())" FontSize="38" FontWeight="Bold" Foreground="#$($p['COLOR_BG'])"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
            <Ellipse x:Name="Avatar" Margin="4"/>
          </Grid>
          <TextBlock HorizontalAlignment="Center" Margin="0,16,0,0" FontSize="13" FontWeight="Bold" Foreground="#$($p['COLOR_ACCENT'])" Text="$(& $x $greeting)"/>
          <TextBlock HorizontalAlignment="Center" Margin="0,2,0,0" FontSize="22" FontWeight="SemiBold" Text="$(& $x $name)"/>
          <TextBlock HorizontalAlignment="Center" Margin="0,2,0,0" FontSize="12" Foreground="#$($p['COLOR_MUTED'])" Text="$(& $x $account)" Visibility="$accountVis"/>

          <Border x:Name="Field" Height="48" CornerRadius="24" Margin="0,22,0,0" BorderThickness="2"
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
              <Button x:Name="Go" Grid.Column="2" Width="36" Height="36" Focusable="False" Cursor="Hand" HorizontalAlignment="Left">
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
          <TextBlock x:Name="Caps" Visibility="Collapsed" HorizontalAlignment="Center" Margin="0,10,0,0" FontSize="12" Foreground="#$($p['COLOR_ACCENT'])">
            <Run FontFamily="Segoe UI Symbol" Text="&#x21EA;"/><Run Text=" $(& $x (T 'greeter.caps'))"/>
          </TextBlock>
          <TextBlock x:Name="Status" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0"
                     MinHeight="16" FontSize="12" Foreground="#$($p['COLOR_MUTED'])"/>

          <Border Margin="0,14,0,0" CornerRadius="10" Padding="6,8" Background="#B3$($p['COLOR_SURFACE'])">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
              $(& $fact (T 'greeter.theme') $theme 0)
              $(& $fact (T 'greeter.host') $env:COMPUTERNAME 1)
              $(& $fact (T 'greeter.network') $net 2)
            </Grid>
          </Border>
        </StackPanel>
      </Border>
    </StackPanel>

    <Grid VerticalAlignment="Bottom" Margin="28,0,28,24">
      <Border HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="10" Padding="12,8" Background="#D9$($p['COLOR_BG'])">
        $(Get-KitHintsXaml $p @(@('Intro', (T 'greeter.hint_enter')), @('Esc', (T 'greeter.hint_clear'))))
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

function Show-VivacLock([switch]$NoShow, [switch]$Greeter) {
    Update-SurfaceContext
    $p = Get-Palette
    $native = Get-LockNative
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $state = @{ Unlocked = $false; Busy = $null; Windows = @(); Armed = $null; ArmedAt = [DateTime]::MinValue }
    $marker = Join-Path (Get-VivacPaths).State 'locked'

    $primaryXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="vivac - lock" WindowStyle="None" ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        Background="#$($p['COLOR_BG'])" Cursor="None"
        FontFamily="JetBrainsMono Nerd Font, Cascadia Mono, Consolas" Foreground="#$($p['COLOR_FG'])">
  <Grid>
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
      <TextBlock x:Name="Clock" HorizontalAlignment="Center" FontSize="96" Margin="0,0,0,40"/>
      <Border x:Name="Field" Width="300" Height="52" CornerRadius="26" BorderThickness="3"
              BorderBrush="#$($p['COLOR_ACCENT'])" Background="#$($p['COLOR_SURFACE'])">
        <Grid>
          <TextBlock x:Name="Placeholder" HorizontalAlignment="Center" VerticalAlignment="Center" FontStyle="Italic"
                     Foreground="#$($p['COLOR_FG_DIM'])" Text="$(ConvertTo-XmlText (T 'lock.placeholder'))"/>
          <PasswordBox x:Name="Secret" Background="Transparent" BorderThickness="0" Foreground="#$($p['COLOR_FG'])"
                       CaretBrush="#$($p['COLOR_ACCENT'])" PasswordChar="&#x25CF;" FontSize="18"
                       HorizontalContentAlignment="Center" VerticalContentAlignment="Center" Margin="16,0"/>
        </Grid>
      </Border>
      <TextBlock x:Name="Status" HorizontalAlignment="Center" Margin="0,18,0,0" Foreground="#$($p['COLOR_MUTED'])"
                 Text="$(ConvertTo-XmlText (T 'lock.hint'))"/>
    </StackPanel>
  </Grid>
</Window>
"@
    # The greeter is dressing: if it cannot be built, the plain lock shows.
    if ($Greeter) {
        try { $primaryXaml = Get-GreeterXaml $p } catch { Write-VivacLockLog "greeter not built, plain lock instead: $_"; $Greeter = $false }
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
    # (tests, previews) has it in place already.
    if ($NoShow) {
        $card = $primary.FindName('Card')
        if ($card) { $card.Opacity = 1; $shift.Y = 0; $card.Triggers.Clear() }
        return $primary
    }

    # One window per screen: the clock and the field on the primary one, the
    # base colour on the rest, so no screen shows the desktop.
    $place = {
        param($w, $screen)
        $src = [System.Windows.Forms.Screen]::PrimaryScreen
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96.0; $g.Dispose()
        $b = $screen.Bounds
        $w.WindowStartupLocation = 'Manual'
        $w.Left = $b.Left / $scale; $w.Top = $b.Top / $scale; $w.Width = $b.Width / $scale; $w.Height = $b.Height / $scale
    }
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
    Write-VivacFile -Path $marker -Text "$PID`n"
    $watch = "`$m='$marker'; while (Test-Path -LiteralPath `$m) { if (-not (Get-Process -Id $PID -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath `$m -Force; rundll32.exe user32.dll,LockWorkStation; break }; Start-Sleep -Milliseconds 500 }"
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $watch -WindowStyle Hidden | Out-Null

    $finish = {
        $state.Unlocked = $true
        [VivacKeys]::LockMode = $false
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $tick.Stop()
        foreach ($w in $state.Windows) { try { $w.Close() } catch { } }
        foreach ($w in $script:LockCover) { try { $w.Close() } catch { } }
        $script:LockCover = @()
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
    $idle = $(if ($Greeter) { '' } else { T 'lock.hint' })
    $reset = {
        $field.BorderBrush = "#$($p['COLOR_ACCENT'])"
        $status.Foreground = "#$($p['COLOR_MUTED'])"
        $status.Text = $idle
    }

    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(250)
    $tick.Add_Tick({
            & $showTime
            # A power button pressed once and left alone asks again.
            if ($state.Armed -and ((Get-Date) - $state.ArmedAt).TotalSeconds -gt 4) { & $disarm }
            # Windows' secure screen took the keyboard (Ctrl+Alt+Del, or its
            # own lock): lock the Windows way and step aside.
            if (-not $state.Busy -and -not $native::OnUserDesktop()) {
                [void]$native::LockWorkStation()
                & $finish
                return
            }
            # A Windows Hello prompt in progress.
            if ($state.Busy) {
                if ($state.Busy.IsCompleted) {
                    $task = $state.Busy; $state.Busy = $null
                    foreach ($w in $state.Windows) { $w.Topmost = $true }
                    if (-not $task.IsFaulted -and [string]$task.Result -eq 'Verified') { & $finish; return }
                    if ($task.IsFaulted -or [string]$task.Result -in 'DeviceNotPresent', 'NotConfiguredForUser', 'DisabledByPolicy', 'DeviceBusy') {
                        [void]$native::LockWorkStation(); & $finish; return
                    }
                    & $fail (T 'lock.hello_failed')
                    [void]$primary.Activate(); [void]$secret.Focus()
                }
                return
            }
            if (-not $primary.IsActive) { Set-VivacForeground $primary; [void]$secret.Focus() }
        })

    $secret.Add_PasswordChanged({ $placeholder.Visibility = $(if ($secret.SecurePassword.Length) { 'Hidden' } else { 'Visible' }); if ($secret.SecurePassword.Length) { & $reset } })
    $primary.Add_PreviewKeyDown({
            param($s, $e)
            if ($state.Busy) { return }
            if ([string]$e.Key -eq 'Escape') { $e.Handled = $true; $secret.Clear(); & $disarm; return }
            if ([string]$e.Key -ne 'Return') { return }
            $e.Handled = $true
            & $submit
        })
    $go = $primary.FindName('Go')
    if ($go) { $go.Add_Click({ if (-not $state.Busy) { & $submit; [void]$secret.Focus() } }) }
    $submit = {
            if (-not $secret.SecurePassword.Length) {
                # Windows Hello draws its own prompt: vivac's windows stop
                # being topmost for as long as it is up, so it can be seen.
                foreach ($w in $state.Windows) { $w.Topmost = $false }
                $status.Text = T 'lock.hello_waiting'
                # If Windows Hello cannot be asked from here, the PIN still
                # works on Windows' own lock: hand over to it rather than
                # leave the field as the only way in.
                try { $state.Busy = Start-HelloVerification } catch {
                    [void]$native::LockWorkStation()
                    & $finish
                }
                return
            }
            $ok = $false
            foreach ($a in (Get-LockAccounts)) {
                if ($native::CheckPassword($a[0], $a[1], $secret.Password)) { $ok = $true; break }
            }
            if ($ok) { & $finish } else { & $fail (T 'lock.wrong') }
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
    $primary.Add_ContentRendered({ Set-VivacForeground $primary; [void]$secret.Focus() })

    [VivacKeys]::LockMode = $true
    foreach ($w in $windows) { if ($w -ne $primary) { $w.Show() } }
    $tick.Start()
    try { [void]$primary.ShowDialog() } finally {
        # Whatever ends the dialog, the keyboard is given back and the
        # watchdog told to stand down only after a real unlock.
        if (-not $state.Unlocked) { [void]$native::LockWorkStation() }
        [VivacKeys]::LockMode = $false
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *
