# Windows Security, drawn by vivac: Defender's state and Malwarebytes' where
# the desktop already looks (one shield on the bar, one surface in the
# palette) instead of two programs' own windows, tray icons and reminders.
#
# Nothing here changes how either protects: scripts/apply-system.ps1
# -Defender does that for Defender, and -SecurityQuiet takes Windows
# Security's tray icon and non-critical notifications away. Threat alerts
# stay the programs' own, so a detection is never shown only when vivac
# happens to be running.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')

$script:Helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-security.ps1'

# Signatures older than this are worth a look; Defender itself updates them
# several times a day.
$script:StaleDays = 3

# Malwarebytes keeps its state in files any user may read, each signed: a
# hash on the first line, then JSON. Only the few values below are taken,
# by pattern, so the licence file's account tokens are never parsed, kept or
# shown. Its service is the one that protects; its window only shows it.
$script:MbData = Join-Path $env:ProgramData 'Malwarebytes\MBAMService'
$script:MbExe = Join-Path $env:ProgramFiles 'Malwarebytes\Anti-Malware\Malwarebytes.exe'
# Its four real-time layers, as its own window names them.
$script:MbLayers = @(@('rtp', 'RtpConfig'), @('web', 'MwacControllerConfig'), @('exploit', 'AeConfig'), @('ransomware', 'ArwControllerConfig'))

function Get-MbValue([string]$Path, [string]$Name) {
    try {
        $m = [regex]::Match([IO.File]::ReadAllText($Path), '"' + $Name + '"\s*:\s*"?([^",}\r\n]*)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    $null
}

function Get-DaysSince([string]$Iso) {
    if (-not $Iso) { return $null }
    try { [int][Math]::Max(0, [Math]::Floor(((Get-Date).ToUniversalTime() - ([datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal'))).TotalDays)) } catch { $null }
}

# $null when Malwarebytes is not installed.
function Get-VivacMalwarebytesStatus {
    if (-not (Test-Path -LiteralPath $script:MbExe)) { return $null }
    $m = [ordered]@{
        Running = $false; Version = ''; Layers = @(); LayersOn = 0; ScanDays = $null; ScanThreats = $null
        DbDays = $null; License = ''; LicenseDays = $null
    }
    $svc = Get-Service -Name MBAMService -ErrorAction SilentlyContinue
    $m.Running = [bool]($svc -and $svc.Status -eq 'Running')
    $m.Version = [string](Get-Item -LiteralPath $script:MbExe).VersionInfo.ProductVersion
    $cfg = Join-Path $script:MbData 'config'
    $layers = foreach ($l in $script:MbLayers) {
        $on = (Get-MbValue (Join-Path $cfg "$($l[1]).json") 'protectionState') -eq 'enabled'
        if ($on) { $m.LayersOn++ }
        [ordered]@{ Id = $l[0]; On = $on }
    }
    $m.Layers = @($layers)
    $scan = Get-ChildItem -LiteralPath (Join-Path $script:MbData 'ScanResults') -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($scan) {
        $m.ScanDays = Get-DaysSince (Get-MbValue $scan.FullName 'scanEndTime')
        $n = Get-MbValue $scan.FullName 'threatsDetected'
        if ($n -match '^\d+$') { $m.ScanThreats = [int]$n }
        $v = Get-MbValue $scan.FullName 'applicationVersion'
        if ($v) { $m.Version = $v }
    }
    $m.DbDays = Get-DaysSince (Get-MbValue (Join-Path $cfg 'UpdateControllerConfig.json') 'db_update_time')
    $lic = Join-Path $cfg 'LicenseConfig.json'
    $m.License = [string](Get-MbValue $lic 'licenseState')
    $end = Get-MbValue $lic 'expirationDate'
    if ($end) {
        try { $m.LicenseDays = [int][Math]::Ceiling(([datetime]::Parse($end, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal') - (Get-Date).ToUniversalTime()).TotalDays) } catch { }
    }
    $m
}

# A trial this close to its end is worth a word; after it Malwarebytes only
# scans by hand.
$script:MbTrialWarnDays = 5

# What Defender, the firewall and Malwarebytes report, and what of it needs a
# look. Each problem is 'alert' (the machine is not protected now) or 'warn'
# (it is, less well than it should be). Nothing here needs elevation.
function Get-VivacSecurityStatus {
    $s = [ordered]@{
        State = 'ok'; Defender = $false; Realtime = $false; SignatureDays = $null; ScanDays = $null
        Tamper = $false; Threats = @(); Recent = 0; Firewall = $null; Malwarebytes = $null; Problems = @()
    }
    $problems = New-Object System.Collections.Generic.List[object]
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp -and $mp.AMServiceEnabled) {
        $s.Defender = $true
        $s.Realtime = [bool]$mp.RealTimeProtectionEnabled
        $s.SignatureDays = [int][Math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays)
        # A scan that never happened is reported as uint32's largest value.
        $ages = @(@($mp.QuickScanAge, $mp.FullScanAge) | Where-Object { $null -ne $_ -and [uint32]$_ -ne [uint32]::MaxValue })
        if ($ages.Count) { $s.ScanDays = [int]($ages | Measure-Object -Minimum).Minimum }
        $s.Tamper = [bool]$mp.IsTamperProtected
        $s.Threats = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive } | ForEach-Object { [string]$_.ThreatName })
        $since = (Get-Date).AddDays(-7)
        $s.Recent = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $since }).Count
        if ($s.Threats.Count) { $problems.Add(@('alert', (T 'security.p_threats' @($s.Threats.Count)))) }
        if (-not $s.Realtime) { $problems.Add(@('alert', (T 'security.p_realtime'))) }
        if ($s.SignatureDays -gt $script:StaleDays) { $problems.Add(@('warn', (T 'security.p_signatures' @($s.SignatureDays)))) }
        if (-not $s.Tamper) { $problems.Add(@('warn', (T 'security.p_tamper'))) }
    } else {
        $problems.Add(@('alert', (T 'security.p_no_defender')))
    }
    # The firewall's own COM object answers in milliseconds where
    # Get-NetFirewallProfile takes seconds. Profiles 1, 2 and 4 are domain,
    # private and public; an inbound action of 1 lets unsolicited traffic in.
    try {
        $fw = New-Object -ComObject HNetCfg.FwPolicy2
        $s.Firewall = -not @(1, 2, 4 | Where-Object { -not $fw.FirewallEnabled($_) -or $fw.DefaultInboundAction($_) -eq 1 }).Count
        if (-not $s.Firewall) { $problems.Add(@('warn', (T 'security.p_firewall'))) }
    } catch { }
    # Defender keeps protecting whatever Malwarebytes does, so nothing about
    # it is more than a warning.
    $mb = Get-VivacMalwarebytesStatus
    $s.Malwarebytes = $mb
    if ($mb) {
        $paid = @('trial', 'licensed', 'premium') -contains $mb.License
        if (-not $mb.Running) { $problems.Add(@('warn', (T 'security.p_mb_stopped'))) }
        elseif ($paid -and $mb.LayersOn -lt $mb.Layers.Count) { $problems.Add(@('warn', (T 'security.p_mb_layers' @($mb.Layers.Count - $mb.LayersOn)))) }
        if ($mb.License -eq 'trial' -and $null -ne $mb.LicenseDays -and $mb.LicenseDays -le $script:MbTrialWarnDays) {
            $problems.Add(@('warn', (T 'security.p_mb_trial' @([Math]::Max(0, $mb.LicenseDays)))))
        }
        if ($mb.DbDays -gt $script:StaleDays) { $problems.Add(@('warn', (T 'security.p_mb_database' @($mb.DbDays)))) }
    }
    $s.Problems = $problems.ToArray()
    if (@($problems | Where-Object { $_[0] -eq 'alert' }).Count) { $s.State = 'alert' }
    elseif ($problems.Count) { $s.State = 'warn' }
    $s
}

# What the bar draws: a state, the few words next to the shield (none when
# all is well, so it recedes like the other gauges) and the tooltip, for
# Defender and Malwarebytes together. antivirus has the shape
# bin/vivac-tray.ps1 -Status gives it, so the shield can stand for both.
function Get-VivacSecuritySummary {
    $s = Get-VivacSecurityStatus
    $text = ''
    $tip = T 'security.ok'
    if ($s.Malwarebytes) { $tip = T 'security.ok_both' }
    if ($s.Problems.Count) {
        $text = $s.Problems[0][1]
        $tip = (@($s.Problems | ForEach-Object { $_[1] }) -join ' - ')
    }
    $out = [ordered]@{ state = $s.State; text = $text; tip = $tip; defender = [bool]$s.Defender; antivirus = $null; malwarebytes = $null }
    $mb = $s.Malwarebytes
    if ($mb) {
        $out.antivirus = [ordered]@{ name = 'Malwarebytes'; running = $mb.Running }
        $out.malwarebytes = [ordered]@{ running = $mb.Running; layers = $mb.LayersOn; of = $mb.Layers.Count; license = $mb.License; days = $mb.LicenseDays }
    }
    $out
}

function Format-Days($Days) {
    if ($null -eq $Days) { return (T 'security.never') }
    if ($Days -le 0) { return (T 'security.today') }
    T 'security.days_ago' @($Days)
}

function Show-Security([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'security' }
    $surfaceName = 'security'
    $p = Get-Palette
    $s = Get-VivacSecurityStatus
    $mb = $s.Malwarebytes
    $tone = @{ ok = $p['COLOR_OK']; warn = $p['COLOR_ACCENT']; alert = $p['COLOR_URGENT']; dim = $p['COLOR_MUTED'] }
    $iconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'

    # The actions, one tile each, numbered for the keys.
    $actions = @(
        @{ Id = 'scan'; Glyph = 0xE721; Sub = 'Defender' },
        @{ Id = 'update'; Glyph = 0xE895; Sub = 'Defender' },
        @{ Id = 'history'; Glyph = 0xE81C; Sub = 'Defender' },
        @{ Id = 'windows'; Glyph = 0xE8A7; Sub = 'Windows' }
    )
    if ($mb) { $actions = @($actions[0], $actions[1], @{ Id = 'malwarebytes'; Glyph = 0xEA18; Sub = (T 'security.open') }, $actions[2], $actions[3]) }
    $tiles = ''
    for ($i = 0; $i -lt $actions.Count; $i++) {
        $a = $actions[$i]
        $label = T "security.$($a.Id)"
        $tiles += @"
<Border x:Name="B$i" Grid.Column="$i" Height="92" Margin="4,0" CornerRadius="10" Cursor="Hand" Background="#$($p['COLOR_SURFACE'])" BorderThickness="0,0,0,3" BorderBrush="Transparent">
  <StackPanel VerticalAlignment="Center">
    <TextBlock HorizontalAlignment="Center" FontFamily="$iconFont" FontSize="22" Foreground="#$($p['COLOR_ACCENT'])" Text="$(Get-KitGlyph $a.Glyph)"/>
    <TextBlock HorizontalAlignment="Center" Margin="0,8,0,0" FontSize="12" Foreground="#$($p['COLOR_FG'])" Text="$(ConvertTo-XmlText $label)"/>
    <TextBlock HorizontalAlignment="Center" Margin="0,1,0,0" FontSize="10" Foreground="#$($p['COLOR_MUTED'])" Text="$($i + 1) - $(ConvertTo-XmlText $a.Sub)"/>
  </StackPanel>
</Border>
"@
    }
    $tileCols = -join @(1..$actions.Count | ForEach-Object { '<ColumnDefinition/>' })

    # A card per program: its name, a chip with its state, and its rows.
    $card = {
        param([string]$Name, [string]$Rows, [string]$Chip, [string]$Col)
        @"
<Border Grid.Column="$Col" Style="{StaticResource KitCard}" Margin="0" VerticalAlignment="Stretch">
  <DockPanel>
    <DockPanel DockPanel.Dock="Top" Margin="2,0,0,6">
      <Border x:Name="$Chip" DockPanel.Dock="Right" CornerRadius="9" Padding="9,2" VerticalAlignment="Center">
        <TextBlock x:Name="${Chip}Text" FontSize="11"/>
      </Border>
      <TextBlock Text="$(ConvertTo-XmlText $Name)" FontSize="13" FontWeight="SemiBold" Foreground="#$($p['COLOR_ACCENT'])" VerticalAlignment="Center"/>
    </DockPanel>
    <StackPanel x:Name="$Rows"/>
  </DockPanel>
</Border>
"@
    }
    $cards = (& $card 'Microsoft Defender' 'DefRows' 'DefChip' '0')
    $width = 560
    $cardCols = '<ColumnDefinition/>'
    if ($mb) {
        $cards += (& $card 'Malwarebytes' 'MbRows' 'MbChip' '2')
        $cardCols = '<ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/>'
        $width = 900
    }

    $body = @"
<StackPanel>
  <Border x:Name="Verdict" CornerRadius="10" Padding="16,14" Margin="0,0,0,12" Background="#$($p['COLOR_SURFACE'])" BorderThickness="4,0,0,0">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="VerdictGlyph" FontFamily="$iconFont" FontSize="30" VerticalAlignment="Center" Margin="2,0,16,0"/>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <TextBlock x:Name="VerdictTitle" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock x:Name="VerdictText" FontSize="12" Margin="0,3,0,0" TextWrapping="Wrap" Foreground="#$($p['COLOR_FG_DIM'])"/>
      </StackPanel>
    </Grid>
  </Border>
  <Grid Margin="0,0,0,12">
    <Grid.ColumnDefinitions>$cardCols</Grid.ColumnDefinitions>
    $cards
  </Grid>
  <TextBlock Text="$(ConvertTo-XmlText (T 'security.actions').ToUpper())" FontSize="11" FontWeight="SemiBold" Foreground="#$($p['COLOR_ACCENT'])" Margin="6,0,0,6"/>
  <Grid Margin="-4,0">
    <Grid.ColumnDefinitions>$tileCols</Grid.ColumnDefinitions>
    $tiles
  </Grid>
</StackPanel>
"@
    $hints = @(@("1-$($actions.Count)", (T 'security.key.pick')), @('&#x2190;&#x2192;', (T 'menu.key.move')), @('&#x21B5;', (T 'menu.key.open')), @('Esc', (T 'security.key.close')))
    $window = New-VivacWindow (Get-WindowXaml 'vivac - security' $width 600 (Get-KitPanelXaml $p 0xEA18 (T 'security.title') $body $hints))
    Set-KitDropDown $window
    $find = { param($n) $window.FindName($n) }
    if ($mb) { (& $find 'Subtitle').Text = T 'security.subtitle_both' } else { (& $find 'Subtitle').Text = 'Microsoft Defender' }

    # The verdict: the state in words, and what to look at.
    $verdict = & $find 'Verdict'
    $verdict.BorderBrush = "#$($tone[$s.State])"
    $vg = & $find 'VerdictGlyph'
    $vg.Foreground = "#$($tone[$s.State])"
    $vg.Text = Get-KitGlyph (@{ ok = 0xE73E; warn = 0xE7BA; alert = 0xE783 }[$s.State])
    $vt = & $find 'VerdictTitle'
    $vt.Text = T "security.verdict_$($s.State)"
    $vt.Foreground = "#$($tone[$s.State])"
    if ($s.Problems.Count) { (& $find 'VerdictText').Text = (@($s.Problems | ForEach-Object { $_[1] }) -join '  -  ') }
    elseif ($mb) { (& $find 'VerdictText').Text = T 'security.verdict_ok_both' }
    else { (& $find 'VerdictText').Text = T 'security.verdict_ok_one' }

    $chip = {
        param([string]$Name, [string]$Text, [string]$Kind)
        $c = & $find $Name
        $c.Background = "#33$($tone[$Kind])"
        $t = & $find "${Name}Text"
        $t.Text = $Text; $t.Foreground = "#$($tone[$Kind])"
    }
    # A row: icon, name, a muted detail under it, and the value in its tone.
    $row = {
        param($Panel, [int]$Glyph, [string]$Name, [string]$Value, [string]$Kind, [string]$Sub = '')
        $v = New-Object Windows.Controls.TextBlock
        $v.Text = $Value; $v.FontSize = 12; $v.Foreground = "#$($tone[$Kind])"
        $v.MaxWidth = 170; $v.TextTrimming = 'CharacterEllipsis'; $v.TextAlignment = 'Right'
        $r = New-KitRow $p $Glyph $Name $Sub $v
        $r.MinHeight = 44
        $r.Tag.Name.FontSize = 13
        [void]$Panel.Children.Add($r)
    }
    $onOff = { param($on, $bad) if ($on) { @((T 'security.on'), 'ok') } else { @((T 'security.off'), $bad) } }

    $def = & $find 'DefRows'
    if ($s.Defender) {
        $chipTone = 'ok'; if ($s.State -eq 'alert') { $chipTone = 'alert' }
        & $chip 'DefChip' (T 'security.active') $chipTone
        $v = & $onOff $s.Realtime 'alert'
        & $row $def 0xEA18 (T 'security.realtime') $v[0] $v[1]
        $sigTone = 'ok'; if ($s.SignatureDays -gt $script:StaleDays) { $sigTone = 'warn' }
        & $row $def 0xE895 (T 'security.signatures') (Format-Days $s.SignatureDays) $sigTone
        & $row $def 0xE721 (T 'security.last_scan') (Format-Days $s.ScanDays) 'dim'
        $v = & $onOff $s.Tamper 'warn'
        & $row $def 0xE72E (T 'security.tamper') $v[0] $v[1]
        if ($s.Threats.Count) { & $row $def 0xE7BA (T 'security.threats') ($s.Threats -join ', ') 'alert' }
        else { & $row $def 0xE7BA (T 'security.threats') (T 'security.none') 'ok' }
        $recentTone = 'dim'; if ($s.Recent) { $recentTone = 'warn' }
        & $row $def 0xE81C (T 'security.recent') ([string]$s.Recent) $recentTone
    } else {
        & $chip 'DefChip' (T 'security.off') 'alert'
        & $row $def 0xE783 'Defender' (T 'security.p_no_defender') 'alert'
    }
    if ($null -ne $s.Firewall) {
        if ($s.Firewall) { & $row $def 0xE968 (T 'security.firewall') (T 'security.firewall_ok') 'ok' }
        else { & $row $def 0xE968 (T 'security.firewall') (T 'security.firewall_open') 'warn' }
    }

    if ($mb) {
        $box = & $find 'MbRows'
        if ($mb.Running) { & $chip 'MbChip' (T 'security.mb_running') 'ok' } else { & $chip 'MbChip' (T 'security.mb_stopped') 'warn' }
        $svcTone = 'ok'; $svc = T 'security.mb_running'
        if (-not $mb.Running) { $svcTone = 'warn'; $svc = T 'security.mb_stopped' }
        & $row $box 0xE9D9 (T 'security.mb_service') $svc $svcTone ("v$($mb.Version)")
        $paid = @('trial', 'licensed', 'premium') -contains $mb.License
        $off = @($mb.Layers | Where-Object { -not $_.On } | ForEach-Object { T "security.mb_layer_$($_.Id)" })
        if ($paid) {
            $layerTone = 'ok'; if ($mb.LayersOn -lt $mb.Layers.Count) { $layerTone = 'warn' }
            $detail = (@($mb.Layers | ForEach-Object { T "security.mb_layer_$($_.Id)" }) -join ' - ')
            if ($off.Count) { $detail = T 'security.mb_layers_off' @($off -join ', ') }
            & $row $box 0xEA18 (T 'security.realtime') (T 'security.mb_layers' @($mb.LayersOn, $mb.Layers.Count)) $layerTone $detail
        } else {
            & $row $box 0xEA18 (T 'security.realtime') (T 'security.mb_manual') 'dim'
        }
        if ($null -eq $mb.ScanDays) { & $row $box 0xE721 (T 'security.last_scan') (T 'security.never') 'dim' }
        elseif ($mb.ScanThreats) { & $row $box 0xE721 (T 'security.last_scan') (T 'security.mb_scan_found' @((Format-Days $mb.ScanDays), $mb.ScanThreats)) 'warn' }
        else { & $row $box 0xE721 (T 'security.last_scan') (T 'security.mb_scan_clean' @(Format-Days $mb.ScanDays)) 'ok' }
        $dbTone = 'ok'; if ($mb.DbDays -gt $script:StaleDays) { $dbTone = 'warn' }
        & $row $box 0xE895 (T 'security.mb_database') (Format-Days $mb.DbDays) $dbTone
        switch ($mb.License) {
            'trial' {
                $licTone = 'dim'; if ($null -ne $mb.LicenseDays -and $mb.LicenseDays -le $script:MbTrialWarnDays) { $licTone = 'warn' }
                $days = '?'; if ($null -ne $mb.LicenseDays) { $days = [Math]::Max(0, $mb.LicenseDays) }
                & $row $box 0xE8D7 (T 'security.mb_license') (T 'security.mb_lic_trial' @($days)) $licTone
            }
            { @('licensed', 'premium') -contains $_ } { & $row $box 0xE8D7 (T 'security.mb_license') 'Premium' 'ok' }
            'expired' { & $row $box 0xE8D7 (T 'security.mb_license') (T 'security.mb_lic_expired') 'warn' }
            default { & $row $box 0xE8D7 (T 'security.mb_license') (T 'security.mb_lic_free') 'dim' }
        }
    }

    $state = @{ Index = 0 }
    $paint = {
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $b = & $find "B$i"
            if ($i -eq $state.Index) { $b.BorderBrush = "#$($p['COLOR_ACCENT'])"; $b.Background = "#$($p['COLOR_SURFACE_ALT'])" }
            else { $b.BorderBrush = 'Transparent'; $b.Background = "#$($p['COLOR_SURFACE'])" }
        }
    }
    # Scans and updates run in a process of their own and report back with a
    # vivac notification, so closing this window does not stop them.
    # Malwarebytes' command line needs elevation and documents no scan for
    # this edition, so its scan is started from its own window.
    $run = {
        param($i)
        $window.Close()
        switch ($actions[$i].Id) {
            'scan'         { Invoke-Detached $script:Helper @('-Scan') }
            'update'       { Invoke-Detached $script:Helper @('-Update') }
            'history'      { Start-Process 'windowsdefender://threat' }
            'windows'      { Start-Process 'windowsdefender:' }
            'malwarebytes' { Start-Process -FilePath $script:MbExe }
        }
    }
    for ($i = 0; $i -lt $actions.Count; $i++) {
        $b = & $find "B$i"
        $b.Tag = $i
        $b.Add_MouseLeftButtonUp({ param($sender) & $run $sender.Tag })
        $b.Add_MouseEnter({ param($sender) $state.Index = $sender.Tag; & $paint })
    }
    $last = $actions.Count
    $window.Add_PreviewKeyDown({
            param($sender, $e)
            $k = [string]$e.Key
            if ($k -eq 'Escape') { $window.Close(); return }
            if ($k -eq 'Left' -and $state.Index -gt 0) { $state.Index--; & $paint; return }
            if ($k -eq 'Right' -and $state.Index -lt $actions.Count - 1) { $state.Index++; & $paint; return }
            if (($k -match '^D(\d)$' -or $k -match '^NumPad(\d)$') -and [int]$Matches[1] -ge 1 -and [int]$Matches[1] -le $last) { & $run ([int]$Matches[1] - 1); return }
            if ($k -eq 'Return' -or $k -eq 'Space') { & $run $state.Index; return }
        })
    & $paint
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Get-VivacSecurityStatus, Get-VivacMalwarebytesStatus, Get-VivacSecuritySummary, Show-Security
