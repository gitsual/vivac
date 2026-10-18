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
    $what = '--all'
    if ($Id) {
        if ($Id -notmatch '^[\w.+-]+$') { return }
        $what = "--id $Id --exact"
    }
    $cmd = "winget upgrade $what --accept-source-agreements --accept-package-agreements"
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

function Show-Updates([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'updates' }
    $surfaceName = 'updates'
    $p = Get-Palette
    $culture = [Globalization.CultureInfo]::GetCultureInfo((Read-VivacSettings)['language'])
    $body = @"
<ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
  <StackPanel x:Name="Body"/>
</ScrollViewer>
"@
    $hints = @(@('F5', (T 'upd.key.refresh')), @('Esc', (T 'upd.key.close')))
    $window = New-VivacWindow (Get-WindowXaml 'vivac - updates' 520 300 (Get-KitPanelXaml $p 0xE895 (T 'upd.title') $body $hints))
    Set-KitDropDown $window
    $root = $window.Content.Child
    $res = $root.Resources
    $panel = $window.FindName('Body')
    $subtitle = $window.FindName('Subtitle')
    $state = @{ Wu = $null; Wg = $null; WuJob = $null; WgJob = $null; Icons = @{}; ArmedReboot = $false }

    $text = {
        param([string]$Text, [string]$Color, [double]$Size = 13, [string]$Weight = 'Normal')
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text; $t.Foreground = "#$Color"; $t.FontSize = $Size; $t.FontWeight = $Weight
        $t.TextTrimming = 'CharacterEllipsis'; $t.VerticalAlignment = 'Center'
        $t
    }
    $button = {
        param([string]$Label, [bool]$Accent, [scriptblock]$OnClick, [int]$Glyph = 0)
        $b = New-Object Windows.Controls.Button
        if ($Accent) { $b.Style = $res['KitButton'] } else { $b.Style = $res['KitGhost'] }
        if ($Glyph) {
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $g = & $text (Get-KitGlyph $Glyph) ($(if ($Accent) { $p['COLOR_BG'] } else { $p['COLOR_FG'] })) 12
            $g.FontFamily = $script:IconFont; $g.Margin = '0,0,7,0'
            [void]$sp.Children.Add($g)
            [void]$sp.Children.Add((& $text $Label ($(if ($Accent) { $p['COLOR_BG'] } else { $p['COLOR_FG'] })) 12))
            $b.Content = $sp
        } else { $b.Content = $Label }
        $b.Margin = '6,0,0,0'
        $b.Add_Click($OnClick)
        $b
    }
    $section = {
        param([string]$Label)
        $t = & $text $Label.ToUpper() $p['COLOR_ACCENT'] 11 'SemiBold'
        $t.Margin = '4,6,0,8'
        [void]$panel.Children.Add($t)
    }
    $card = {
        $c = New-Object Windows.Controls.Border
        $c.Style = $res['KitCard']
        $s = New-Object Windows.Controls.StackPanel
        $c.Child = $s
        [void]$panel.Children.Add($c)
        $s
    }
    # A glyph that turns while an answer is awaited.
    $spinner = {
        $t = & $text (Get-KitGlyph 0xE72C) $p['COLOR_ACCENT'] 16
        $t.FontFamily = $script:IconFont
        $t.RenderTransformOrigin = '0.5,0.5'
        $rt = New-Object Windows.Media.RotateTransform
        $t.RenderTransform = $rt
        $anim = New-Object Windows.Media.Animation.DoubleAnimation 0, 360, ([TimeSpan]::FromSeconds(1.2))
        $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $anim)
        $t
    }
    $loadingRow = {
        param([int]$Glyph, [string]$Name)
        New-KitRow $p $Glyph $Name (T 'upd.checking') (& $spinner)
    }
    $when = {
        param($Date)
        if (-not $Date) { return T 'upd.never_checked' }
        T 'upd.last_check' @(([datetime]$Date).ToString('g', $culture))
    }

    $render = {
        $panel.Children.Clear()
        $wu = $state.Wu; $wg = $state.Wg
        $apps = @()
        if ($wg -and -not $wg.Missing -and -not $wg.Error) { $apps = @(ConvertFrom-VivacWingetTable $wg.Text) }

        # Windows Update.
        & $section (T 'upd.windows')
        $c = & $card
        if (-not $wu -or $state.WuJob) {
            [void]$c.Children.Add((& $loadingRow 0xE895 (T 'upd.windows')))
        } elseif ($wu.Error) {
            [void]$c.Children.Add((New-KitRow $p 0xE783 (T 'upd.windows') (T 'upd.error' @($wu.Error)) $null $p['COLOR_URGENT']))
        } else {
            $n = @($wu.Updates).Count
            $right = New-Object Windows.Controls.StackPanel
            $right.Orientation = 'Horizontal'
            [void]$right.Children.Add((& $button (T 'upd.check') $false { & $checkWindows } 0xE72C))
            if ($n) {
                [void]$right.Children.Add((& $button (T 'upd.install') $true { $window.Close(); Start-Process 'ms-settings:windowsupdate-action' } 0xE896))
                $headline = if ($n -eq 1) { T 'upd.pending_one' } else { T 'upd.pending' @($n) }
                [void]$c.Children.Add((New-KitRow $p 0xE895 $headline (& $when $wu.LastCheck) $right))
                foreach ($u in $wu.Updates) {
                    $glyph = 0xE895
                    # Definition updates (Defender's) and drivers, by their category ids.
                    if ($u.Categories -match 'e0789628-ce08-4437-be74-2495b842f43b') { $glyph = 0xEA18 }
                    elseif ($u.Categories -match 'ebfc1fc5-71a4-4f7b-9aca-3b9a503104a0') { $glyph = 0xE772 }
                    $bits = @($u.KB, (Format-UpdateSize $u.Size)) | Where-Object { $_ }
                    if ($u.Downloaded) { $bits += T 'upd.downloaded' }
                    [void]$c.Children.Add((New-KitRow $p $glyph $u.Title ($bits -join '  -  ')))
                }
            } else {
                [void]$c.Children.Add((New-KitRow $p 0xE73E (T 'upd.up_to_date') (& $when $wu.LastCheck) $right $p['COLOR_OK']))
            }
            if ($wu.Reboot) {
                $rb = & $button (T 'upd.reboot_button') $true {
                    param($s)
                    if (-not $state.ArmedReboot) { $state.ArmedReboot = $true; $s.Background = "#$($p['COLOR_URGENT'])"; $s.Content = T 'upd.confirm'; return }
                    $window.Close()
                    Start-Process shutdown.exe -ArgumentList '/r', '/t', '0' -WindowStyle Hidden
                } 0xE777
                [void]$c.Children.Add((New-KitRow $p 0xE7BA (T 'upd.reboot') '' $rb $p['COLOR_URGENT']))
            }
            if (@($wu.History).Count) {
                $h = & $text (T 'upd.history') $p['COLOR_MUTED'] 11
                $h.Margin = '2,10,0,2'
                [void]$c.Children.Add($h)
                foreach ($x in $wu.History) {
                    $ok = if ($x.Ok) { T 'upd.ok' } else { T 'upd.failed' }
                    $color = if ($x.Ok) { $p['COLOR_MUTED'] } else { $p['COLOR_URGENT'] }
                    $row = New-KitRow $p ($(if ($x.Ok) { 0xE73E } else { 0xE783 })) $x.Title "$($x.Date.ToString('g', $culture))  -  $ok" $null $color
                    $row.MinHeight = 40
                    $row.Tag.Name.FontSize = 12
                    [void]$c.Children.Add($row)
                }
            }
        }

        # The programs.
        & $section (T 'upd.apps')
        $c = & $card
        if (-not $wg -or $state.WgJob) {
            [void]$c.Children.Add((& $loadingRow 0xE71D (T 'upd.apps')))
        } elseif ($wg.Missing) {
            [void]$c.Children.Add((New-KitRow $p 0xE7BA (T 'upd.no_winget') '' $null $p['COLOR_URGENT']))
        } elseif ($wg.Error) {
            [void]$c.Children.Add((New-KitRow $p 0xE783 (T 'upd.apps') (T 'upd.error' @($wg.Error)) $null $p['COLOR_URGENT']))
        } elseif (-not $apps.Count) {
            [void]$c.Children.Add((New-KitRow $p 0xE73E (T 'upd.apps_up_to_date') 'winget' $null $p['COLOR_OK']))
        } else {
            $all = & $button (T 'upd.update_all') $true { $window.Close(); Start-VivacWinget } 0xE896
            [void]$c.Children.Add((New-KitRow $p 0xE71D (T 'upd.apps_pending' @($apps.Count)) 'winget' $all))
            foreach ($a in $apps) {
                $one = & $button (T 'upd.update') $false { param($s) $window.Close(); Start-VivacWinget $s.Tag }
                $one.Tag = $a.Id
                $row = New-KitRow $p 0xE71D $a.Name "$($a.Version)  $([char]0x2192)  $($a.Available)  -  $($a.Source)" $one
                # The application's own icon when the Start menu lists it by a
                # name that starts like the package's.
                $key = ($a.Name -replace [char]0x2026, '').Trim()
                $match = @($wg.Apps | Where-Object { $key -and $_.Name -like "$key*" }) | Select-Object -First 1
                if (-not $match) { $match = @($wg.Apps | Where-Object { $_.Name -and $key -like "$($_.Name)*" }) | Select-Object -First 1 }
                if ($match) { $state.Icons["shell:AppsFolder\$($match.AppID)"] = $row.Tag.Tile }
                [void]$c.Children.Add($row)
            }
            if ($state.Icons.Count) {
                try { Import-VivacMenu; [VivacIcons]::Warm([string[]]@($state.Icons.Keys)) } catch { $state.Icons.Clear() }
            }
        }

        $more = & $text (T 'upd.settings') $p['COLOR_INFO'] 12
        $more.Cursor = 'Hand'; $more.Margin = '4,2,0,0'
        $more.Add_MouseLeftButtonUp({ $window.Close(); Start-Process 'ms-settings:windowsupdate' })
        [void]$panel.Children.Add($more)

        # What the header says.
        $parts = @()
        if ($wu -and -not $state.WuJob -and -not $wu.Error) { $parts += @($wu.Updates).Count }
        if ($wg -and -not $state.WgJob -and -not $wg.Missing -and -not $wg.Error) { $parts += $apps.Count }
        if ($state.WuJob -or $state.WgJob -or -not $wu -or -not $wg) { $subtitle.Text = T 'upd.checking' }
        else {
            $total = ($parts | Measure-Object -Sum).Sum
            if ($wu -and $wu.Reboot) { $subtitle.Text = T 'upd.reboot' }
            elseif ($total) { $subtitle.Text = T 'upd.subtitle_pending' @([int]$total) }
            else { $subtitle.Text = T 'upd.subtitle_ok' }
        }
    }

    $checkWindows = {
        if ($state.WuJob) { return }
        $state.WuJob = Start-UpdatesJob $script:WindowsUpdateJob @($true)
        & $render
    }
    $refresh = {
        if (-not $state.WuJob) { $state.WuJob = Start-UpdatesJob $script:WindowsUpdateJob @($true) }
        if (-not $state.WgJob) { $state.WgJob = Start-UpdatesJob $script:WingetJob }
        & $render
    }

    $refreshButton = & $button '' $false { & $refresh } 0xE72C
    $refreshButton.ToolTip = T 'upd.key.refresh'
    [void]$window.FindName('HeaderRight').Children.Add($refreshButton)

    # Answers are collected, and icons put in place, on this thread.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
            $changed = $false
            $r = Receive-UpdatesJob $state.WuJob
            if ($r) { $state.Wu = $r; $state.WuJob = $null; $changed = $true }
            $r = Receive-UpdatesJob $state.WgJob
            if ($r) { $state.Wg = $r; $state.WgJob = $null; $changed = $true }
            if ($changed) { & $render }
            foreach ($k in @($state.Icons.Keys)) {
                $img = $null
                try { $img = [VivacIcons]::Get($k) } catch { }
                if ($img) {
                    $i = New-Object Windows.Controls.Image
                    $i.Source = $img; $i.Width = 24; $i.Height = 24
                    [Windows.Media.RenderOptions]::SetBitmapScalingMode($i, 'HighQuality')
                    $state.Icons[$k].Child = $i
                    $state.Icons.Remove($k)
                } elseif ([VivacIcons]::IsMissing($k)) { $state.Icons.Remove($k) }
            }
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
            if ($e.Key -eq 'Escape') { $window.Close(); $e.Handled = $true }
            elseif ($e.Key -eq 'F5') { & $refresh; $e.Handled = $true }
        })
    & $render
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Updates, ConvertFrom-VivacWingetTable
