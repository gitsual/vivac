# The updates panel, drawn by vivac: what Windows Update has waiting (and a
# restart it waits for), and the installed programs winget can bring up to
# date, dropping from the bar's right end where its update icon sits, as the
# sound panel does.
#
# Asking takes seconds (Windows Update's own cache about four, winget about
# two), so the panel opens at once and fills in as the answers come, each
# asked on a runspace of its own. "Check now" asks Windows Update's servers,
# not only its cache. Nothing installs from here without a click: Windows'
# updates install through Settings (the one place that may do it without
# elevation), the programs' in a Windows Terminal tab, so what winget does
# and asks stays in view.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

$script:IconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'

# Windows Update, from its COM API. Online asks the servers; otherwise the
# answer is what the last scan left in the cache.
$script:WindowsUpdateJob = {
    param([bool]$Online)
    $out = [ordered]@{ Error = $null; Updates = @(); History = @(); LastCheck = $null; Reboot = $false }
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $searcher.Online = $Online
        foreach ($u in $searcher.Search('IsInstalled=0 and IsHidden=0').Updates) {
            $out.Updates += [pscustomobject]@{
                Title = [string]$u.Title; KB = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
                Size = [double]$u.MaxDownloadSize; Downloaded = [bool]$u.IsDownloaded
                Categories = (@($u.Categories | ForEach-Object { [string]$_.CategoryID }) -join ' ')
            }
        }
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($h in $searcher.QueryHistory(0, [Math]::Min(4, $count))) {
                $out.History += [pscustomobject]@{ Title = [string]$h.Title; Date = ([datetime]$h.Date).ToLocalTime(); Ok = ([int]$h.ResultCode -eq 2) }
            }
        }
        if ($Online) { $out.LastCheck = Get-Date }
    } catch { $out.Error = $_.Exception.Message }
    if (-not $out.LastCheck) {
        try { $out.LastCheck = ([datetime](New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastSearchSuccessDate).ToLocalTime() } catch { }
    }
    $out.Reboot = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    [pscustomobject]$out
}

# winget's table as it prints it, and the Start menu's applications, whose
# icons the rows borrow.
$script:WingetJob = {
    $out = [ordered]@{ Missing = $false; Error = $null; Text = ''; Apps = @() }
    $exe = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $exe) { $out.Missing = $true }
    else {
        try {
            $psi = New-Object Diagnostics.ProcessStartInfo $exe.Source, 'upgrade --accept-source-agreements --disable-interactivity'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
            $proc = [Diagnostics.Process]::Start($psi)
            $out.Text = $proc.StandardOutput.ReadToEnd()
            [void]$proc.WaitForExit(120000)
        } catch { $out.Error = $_.Exception.Message }
    }
    try { $out.Apps = @(Get-StartApps | ForEach-Object { [pscustomobject]@{ Name = $_.Name; AppID = $_.AppID } }) } catch { }
    [pscustomobject]$out
}

# winget prints a table whose header is in the system's language, so the
# columns are found by where the header's words start, not by their names:
# name, id, installed version, available version, source. A spinner may
# precede it on the same line, behind carriage returns; lines after the table
# (the count, the pinned packages) do not fill the available column.
function ConvertFrom-VivacWingetTable([string]$Text) {
    $lines = @($Text -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() })
    $rows = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{10,}$') { continue }
        $header = $lines[$i - 1]
        $starts = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 4) { continue }
        $cut = {
            param([string]$Line, [int]$Col)
            $from = $starts[$Col]
            if ($Line.Length -le $from) { return '' }
            $to = $Line.Length
            if ($Col + 1 -lt $starts.Count) { $to = [Math]::Min($Line.Length, $starts[$Col + 1]) }
            $Line.Substring($from, $to - $from).Trim()
        }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if (-not $line.Trim()) { break }
            $id = & $cut $line 1
            $available = & $cut $line 3
            if ($id -notmatch '^[\w.+-]+$' -or -not $available) { break }
            $source = ''
            if ($starts.Count -ge 5) { $source = & $cut $line 4 }
            $rows += [pscustomobject]@{
                Name = $line.Substring(0, [Math]::Min($line.Length, $starts[1])).Trim(); Id = $id
                Version = & $cut $line 2; Available = $available; Source = $source
            }
        }
    }
    $rows
}

function Format-UpdateSize([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:0.0} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -gt 0) { return '{0:0} KB' -f ($Bytes / 1KB) }
    ''
}

# A winget command in a Windows Terminal tab of its own, left open so its
# outcome can be read. Ids are checked: they reach a command line.
function Start-VivacWinget([string]$Id = '') {
    if ($Id -and $Id -notmatch '^[\w.+-]+$') { return }
    # Through the elevated task (scripts/register-winget.ps1) when it exists:
    # no UAC prompt for each installer to stop at. Plain winget otherwise.
    if (Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -ErrorAction SilentlyContinue) {
        $cmd = "& '$(Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-winget.ps1')' -Queue upgrade -Follow"
        if ($Id) { $cmd += " -Id $Id" }
    } else {
        $what = '--all'
        if ($Id) { $what = "--id $Id --exact" }
        $cmd = "winget upgrade $what --accept-source-agreements --accept-package-agreements"
    }
    Start-Process -FilePath 'wt.exe' -ArgumentList @('-w', '0', 'new-tab', '--title', "`"$(T 'upd.terminal')`"", 'powershell.exe', '-NoProfile', '-NoExit', '-Command', $cmd)
}

function Start-UpdatesJob([scriptblock]$Script, [object[]]$Arguments = @()) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

# The job's answer once it has one, else $null.
function Receive-UpdatesJob($Job) {
    if (-not $Job -or -not $Job.Handle.IsCompleted) { return $null }
    try { $r = $Job.PS.EndInvoke($Job.Handle) } finally { $Job.PS.Dispose() }
    if ($r -and $r.Count) { return $r[0] }
    $null
}

# What the panel shows, apart from drawing it: the total, the origins with
# their counts (the bar and its legend), and the first rows, Windows Update's
# before the programs'. $WuUpdates are the objects the Windows Update job
# returns; $Apps the rows ConvertFrom-VivacWingetTable reads.
function Get-VivacUpdatesModel([object[]]$WuUpdates = @(), [object[]]$Apps = @(), [int]$Limit = 5) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($u in @($WuUpdates)) {
        $bits = @($u.KB, (Format-UpdateSize $u.Size)) | Where-Object { $_ }
        $items.Add([pscustomobject]@{ Origin = 'windows'; Name = [string]$u.Title; Sub = ($bits -join '  -  '); Id = '' })
    }
    foreach ($a in @($Apps)) {
        $items.Add([pscustomobject]@{ Origin = 'winget'; Name = [string]$a.Name; Sub = "$($a.Version)  $([char]0x2192)  $($a.Available)"; Id = [string]$a.Id })
    }
    $groups = @()
    if (@($WuUpdates).Count) { $groups += [pscustomobject]@{ Origin = 'windows'; Count = @($WuUpdates).Count } }
    if (@($Apps).Count) { $groups += [pscustomobject]@{ Origin = 'winget'; Count = @($Apps).Count } }
    [pscustomobject]@{
        Total = $items.Count; Groups = $groups; First = @($items | Select-Object -First $Limit); More = ($items.Count -gt $Limit)
    }
}

# "just now", "2 min ago", "3 h ago", "4 days ago".
function Format-UpdatesAgo($Date, [datetime]$Now = (Get-Date)) {
    if (-not $Date) { return (T 'upd.never_checked') }
    $span = $Now - [datetime]$Date
    if ($span.TotalMinutes -lt 1) { return (T 'upd.checked_now') }
    if ($span.TotalHours -lt 1) { $text = T 'upd.ago_min' @([int]$span.TotalMinutes) }
    elseif ($span.TotalDays -lt 1) { $text = T 'upd.ago_h' @([int]$span.TotalHours) }
    else { $text = T 'upd.ago_d' @([int]$span.TotalDays) }
    T 'upd.checked' @($text)
}

function Show-Updates([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'updates' }
    $surfaceName = 'updates'
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $origin = @{ windows = @{ Color = $t.accent; Label = (T 'upd.windows'); Chip = 'Windows' }; winget = @{ Color = $t.info; Label = 'winget'; Chip = 'winget' } }

    $body = @"
<ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-8,0">
  <ContentControl x:Name="Body" Margin="0,0,8,0" IsTabStop="False"/>
</ScrollViewer>
"@
    $hints = @(@("$([char]0x2191)$([char]0x2193)", (T 'upd.key.move')), @([string][char]0x21B5, (T 'upd.key.update')), @('F5', (T 'upd.key.check')), @('Esc', (T 'upd.key.close')))
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - updates' 440 (Get-KitPanelXamlV2 $t (Get-KitGlyph 0xE895) (T 'upd.title') $body $hints))
    Add-KitDrawResources $window $p
    Set-KitDropDown $window
    # The refresh button sits in the header's slot.
    $refreshBtn = ConvertTo-PanelElement (Get-PanelButtonXaml $t 'BtnRefresh' '' 'refresh' 'neutral' 34 'Width="34" ToolTip="F5"')
    [void]$window.FindName('HeaderRight').Children.Add($refreshBtn)
    $bodyHost = $window.FindName('Body')
    $subtitle = $window.FindName('Subtitle')
    $state = @{ Wu = $null; Wg = $null; WuJob = $null; WgJob = $null; ArmedReboot = $false; Items = @() }

    $card = {
        param([string]$Inner, [string]$Margin = '0')
        "<Border Margin=`"$Margin`" Background=`"#$($t.surface)`" CornerRadius=`"12`" Padding=`"14`">$Inner</Border>"
    }

    $render = {
        $wu = $state.Wu; $wg = $state.Wg
        $wuBusy = [bool]($state.WuJob -or -not $wu)
        $wgBusy = [bool]($state.WgJob -or -not $wg)
        $apps = @()
        if ($wg -and -not $wg.Missing -and -not $wg.Error) { $apps = @(ConvertFrom-VivacWingetTable $wg.Text) }
        $wuList = @()
        if ($wu -and -not $wu.Error) { $wuList = @($wu.Updates) }
        $m = Get-VivacUpdatesModel $wuList $apps
        $state.Items = $m.First
        $busy = $wuBusy -or $wgBusy
        $reboot = [bool]($wu -and -not $wu.Error -and $wu.Reboot)

        # Problems are said where the numbers are, with a shape.
        $notes = ''
        $problem = {
            param([string]$Text)
            "<StackPanel Orientation=`"Horizontal`" Margin=`"0,8,0,0`"><Grid VerticalAlignment=`"Top`" Margin=`"0,2,0,0`">$(Get-PanelIconXaml 'warn' 14 $t.alert 2.2)</Grid><TextBlock Text=`"$(ConvertTo-XmlText $Text)`" Margin=`"8,0,0,0`" FontSize=`"12`" TextWrapping=`"Wrap`" MaxWidth=`"340`" Foreground=`"#$($t.alertText)`"/></StackPanel>"
        }
        if ($wu -and $wu.Error) { $notes += & $problem "$(T 'upd.windows'): $(T 'upd.error' @($wu.Error))" }
        if ($wg -and $wg.Missing) { $notes += & $problem (T 'upd.no_winget') }
        elseif ($wg -and $wg.Error) { $notes += & $problem "winget: $(T 'upd.error' @($wg.Error))" }

        # The total, large, and what it counts.
        if ($m.Total) { $big = "<TextBlock Text=`"$($m.Total)`" FontSize=`"40`" FontWeight=`"Bold`" Foreground=`"#$($t.text)`" VerticalAlignment=`"Bottom`"/><TextBlock Text=`"$(ConvertTo-XmlText (T 'upd.caption'))`" FontSize=`"13`" Margin=`"8,0,0,6`" Foreground=`"#$($t.textSecondary)`" VerticalAlignment=`"Bottom`"/>" }
        elseif ($busy) { $big = "<TextBlock Text=`"$(ConvertTo-XmlText (T 'upd.checking'))`" FontSize=`"22`" FontWeight=`"Bold`" Foreground=`"#$($t.text)`"/>" }
        else { $big = "<Grid VerticalAlignment=`"Center`">$(Get-PanelIconXaml 'check' 34 $t.success 2.4)</Grid><TextBlock Text=`"$(ConvertTo-XmlText (T 'upd.caption_ok'))`" FontSize=`"22`" FontWeight=`"Bold`" Margin=`"12,0,0,0`" Foreground=`"#$($t.text)`" VerticalAlignment=`"Center`"/>" }
        $heroRows = "<StackPanel Orientation=`"Horizontal`">$big</StackPanel>"

        if ($reboot) {
            $rb = Get-PanelButtonXaml $t 'BtnReboot' (T 'upd.reboot_button') '' 'neutral' 26 'Margin="8,0,0,0"'
            $heroRows += "<Border Margin=`"0,12,0,0`" Background=`"#$($t.bg)`" CornerRadius=`"8`" Padding=`"10,7`"><DockPanel><ContentControl DockPanel.Dock=`"Right`" Focusable=`"False`">$rb</ContentControl><StackPanel Orientation=`"Horizontal`" VerticalAlignment=`"Center`"><Grid VerticalAlignment=`"Center`">$(Get-PanelIconXaml 'restart' 14 $t.accent)</Grid><TextBlock Text=`"$(ConvertTo-XmlText (T 'upd.reboot_note'))`" Margin=`"8,0,0,0`" FontSize=`"12`" Foreground=`"#$($t.accent)`" VerticalAlignment=`"Center`"/></StackPanel></DockPanel></Border>"
        }
        if ($m.Groups.Count) {
            $cols = New-Object System.Text.StringBuilder; $cells = New-Object System.Text.StringBuilder; $i = 0
            foreach ($g in $m.Groups) {
                if ($i) { [void]$cols.Append('<ColumnDefinition Width="3"/>') }
                [void]$cols.Append("<ColumnDefinition Width=`"$($g.Count)*`"/>")
                [void]$cells.Append("<Border Grid.Column=`"$($i * 2)`" Height=`"12`" CornerRadius=`"3`" Background=`"#$($origin[$g.Origin].Color)`"/>")
                $i++
            }
            $heroRows += "<Grid Margin=`"0,12,0,0`"><Grid.ColumnDefinitions>$($cols.ToString())</Grid.ColumnDefinitions>$($cells.ToString())</Grid>"
            $legend = foreach ($g in $m.Groups) {
                "<StackPanel Orientation=`"Horizontal`" Margin=`"0,0,16,0`"><Border Width=`"10`" Height=`"10`" CornerRadius=`"3`" Background=`"#$($origin[$g.Origin].Color)`" VerticalAlignment=`"Center`"/><TextBlock Text=`"$(ConvertTo-XmlText $origin[$g.Origin].Label)`" Margin=`"6,0,4,0`" FontSize=`"12`"/><TextBlock Text=`"$($g.Count)`" FontSize=`"12`" FontWeight=`"Bold`"/></StackPanel>"
            }
            $heroRows += "<WrapPanel Margin=`"0,12,0,0`">$(-join $legend)</WrapPanel>"
        }
        $heroRows += $notes
        if ($m.Total) { $heroRows += "<Grid Margin=`"0,14,0,0`">$(Get-PanelButtonXaml $t 'BtnAll' (T 'upd.update_all') 'download' 'primary' 38)</Grid>" }
        $xaml = "<StackPanel>$(& $card "<StackPanel>$heroRows</StackPanel>")"

        # The first rows, each with the colour of its origin along the edge.
        if ($m.Total) {
            $head = T 'upd.pending_list'
            $note = ''
            if ($m.More) { $head = T 'upd.first'; $note = T 'upd.of' @($m.Total) }
            $xaml += "<Grid Margin=`"0,14,0,8`">$(Get-PanelSectionXaml $t $head $note @($m.First).Count '0')</Grid>"
            $n = 0
            foreach ($it in $m.First) {
                $btn = Get-PanelButtonXaml $t "R$n" (T 'upd.update') '' 'neutral' 30
                $xaml += @"
<Border Margin="0,0,0,6" Background="#$($t.surface)" CornerRadius="10" BorderThickness="3,0,0,0" BorderBrush="#$($origin[$it.Origin].Color)" Padding="9,8,10,8">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$(ConvertTo-XmlText $it.Name)" FontSize="13" FontWeight="Bold" TextTrimming="CharacterEllipsis" Foreground="#$($t.text)"/>
      <TextBlock Text="$(ConvertTo-XmlText $it.Sub)" FontSize="12" TextTrimming="CharacterEllipsis" Foreground="#$($t.textSecondary)"/>
    </StackPanel>
    <Grid Grid.Column="1" Margin="10,0">$(Get-PanelChipXaml $t 'plain' $origin[$it.Origin].Chip)</Grid>
    <Grid Grid.Column="2">$btn</Grid>
  </Grid>
</Border>
"@
                $n++
            }
        }
        $xaml += '</StackPanel>'
        $view = ConvertTo-PanelElement $xaml
        $bodyHost.Content = $view

        # Everything installs from outside this window, so it closes first.
        $install = {
            param($Item)
            if ($Item.Origin -eq 'winget') { Start-VivacWinget $Item.Id } else { Start-Process 'ms-settings:windowsupdate-action' }
        }
        for ($i = 0; $i -lt @($m.First).Count; $i++) {
            $b = $view.FindName("R$i")
            $b.Tag = $m.First[$i]
            $b.Add_Click({ param($s2, $e2) $window.Close(); & $install $s2.Tag }.GetNewClosure())
        }
        $all = $view.FindName('BtnAll')
        if ($all) {
            $hasWu = [bool]$wuList.Count; $hasApps = [bool]$apps.Count
            $all.Add_Click({
                    $window.Close()
                    if ($hasApps) { Start-VivacWinget }
                    if ($hasWu) { Start-Process 'ms-settings:windowsupdate-action' }
                }.GetNewClosure())
        }
        $rb = $view.FindName('BtnReboot')
        if ($rb) {
            $rb.Add_Click({
                    param($s2, $e2)
                    if (-not $state.ArmedReboot) {
                        $state.ArmedReboot = $true
                        $s2.Content = $null
                        $s2.Background = "#$($t.alert)"
                        $tb = New-Object Windows.Controls.TextBlock
                        $tb.Text = T 'upd.confirm'; $tb.Foreground = "#$($t.bg)"; $tb.FontWeight = 'Bold'; $tb.FontSize = 12
                        $s2.Content = $tb
                        return
                    }
                    $window.Close()
                    Start-Process shutdown.exe -ArgumentList '/r', '/t', '0' -WindowStyle Hidden
                })
        }

        # What the header says.
        if ($busy -and -not $m.Total) { $subtitle.Text = T 'upd.checking' }
        elseif ($wu -and $wu.LastCheck) { $subtitle.Text = Format-UpdatesAgo $wu.LastCheck }
        elseif ($m.Total) { $subtitle.Text = T 'upd.subtitle_pending' @([int]$m.Total) }
        else { $subtitle.Text = T 'upd.subtitle_ok' }
        # The first thing to press has the focus ring, as in the design.
        $focus = $view.FindName('BtnAll')
        if (-not $focus) { $focus = $view.FindName('R0') }
        if ($focus -and $window.IsLoaded -and -not $refreshBtn.IsKeyboardFocused) { [void]$focus.Focus() }
    }

    $refresh = {
        if (-not $state.WuJob) { $state.WuJob = Start-UpdatesJob $script:WindowsUpdateJob @($true) }
        if (-not $state.WgJob) { $state.WgJob = Start-UpdatesJob $script:WingetJob }
        & $render
    }
    $refreshBtn.Add_Click({ & $refresh })

    # Answers are collected on this thread.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
            $changed = $false
            $r = Receive-UpdatesJob $state.WuJob
            if ($r) { $state.Wu = $r; $state.WuJob = $null; $changed = $true }
            $r = Receive-UpdatesJob $state.WgJob
            if ($r) { $state.Wg = $r; $state.WgJob = $null; $changed = $true }
            if ($changed) { & $render }
        })
    # Asked once the panel is up, the cache first: it answers in seconds.
    $window.Add_ContentRendered({
            $state.WuJob = Start-UpdatesJob $script:WindowsUpdateJob @($false)
            $state.WgJob = Start-UpdatesJob $script:WingetJob
            $timer.Start()
        })
    # Through the window: closing may come after this function has returned
    # (the resident host builds the panel once and closes it unseen).
    $window.Tag = $timer
    $window.Add_Closed({ param($s) if ($s.Tag) { $s.Tag.Stop() } })
    $window.Add_PreviewKeyDown({
            param($s, $e)
            $k = [string]$e.Key
            if ($k -eq 'Escape') { $window.Close(); $e.Handled = $true }
            elseif ($k -eq 'F5') { & $refresh; $e.Handled = $true }
            elseif ($k -eq 'Down' -or $k -eq 'Up') {
                $focused = [Windows.Input.Keyboard]::FocusedElement
                if ($focused -is [Windows.UIElement]) {
                    $dir = if ($k -eq 'Down') { 'Next' } else { 'Previous' }
                    [void]$focused.MoveFocus((New-Object Windows.Input.TraversalRequest $dir))
                }
                $e.Handled = $true
            }
        })
    $window.Add_Loaded({
            $first = $window.FindName('Body').Content.FindName('BtnAll')
            if ($first) { [void]$first.Focus() }
        })
    & $render
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Updates, ConvertFrom-VivacWingetTable, Get-VivacUpdatesModel, Format-UpdatesAgo
