# Windows Security, drawn by vivac: what Windows' own Security Center
# registers (every antivirus and firewall, by name and state), Defender's
# detail, Avast's and Malwarebytes' where the desktop already looks (one
# shield on the bar, one surface in the palette) instead of each program's
# own windows, tray icons and reminders.
#
# Nothing here changes how any of them protects: scripts/apply-system.ps1
# -Defender does that for Defender, and -SecurityQuiet takes Windows
# Security's tray icon and non-critical notifications away. Threat alerts
# stay the programs' own, so a detection is never shown only when vivac
# happens to be running.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

$script:Helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-security.ps1'

# Signatures older than this are worth a look; Defender itself updates them
# several times a day.
$script:StaleDays = 3

# ------------------------------------------------------------ Security Center

# What Windows itself registers in root/SecurityCenter2: one row per
# antivirus and per firewall, as Windows Security lists them. productState
# reads as 0xAABBCC: BB is the state (0x10 or 0x11 on; 0x20 snoozed, as
# Avast reports its shields paused; anything else off, which is also what
# Defender reports once another antivirus has it in passive mode) and CC
# says whether the product calls itself up to date (0x00) or not (0x10).
function Get-VivacSecurityProducts {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($kind in @(@('av', 'AntiVirusProduct'), @('fw', 'FirewallProduct'))) {
        $items = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName $kind[1] -ErrorAction SilentlyContinue)
        foreach ($i in $items) {
            $st = [int]$i.productState
            $bb = ($st -shr 8) -band 0xFF
            $cc = $st -band 0xFF
            $state = 'off'
            if ($bb -eq 0x10 -or $bb -eq 0x11) { $state = 'on' } elseif ($bb -eq 0x20) { $state = 'snoozed' }
            $name = [string]$i.displayName
            $vendor = 'other'
            if ($name -match 'Defender') { $vendor = 'defender' }
            elseif ($name -match 'Avast') { $vendor = 'avast' }
            elseif ($name -match 'Malwarebytes') { $vendor = 'malwarebytes' }
            elseif ($name -match 'Bitdefender') { $vendor = 'bitdefender' }
            $out.Add([ordered]@{ Kind = $kind[0]; Name = $name; Vendor = $vendor; State = $state; UpToDate = ($cc -eq 0) })
        }
    }
    $out.ToArray()
}

# ---------------------------------------------------------------------- Avast

# Avast One keeps its settings sealed, so what is read is what it publishes:
# its service, its version, the newest definitions folder (named by date,
# yyMMddNN) and its firewall service; whether its shields are on, paused or
# off is what it tells the Security Center. Its window is AvastUI /gui and
# its definitions update is ashUpd vps, both of its own.
$script:AvastDir = Join-Path $env:ProgramFiles 'Avast Software\Suite'
$script:AvastUI = Join-Path $script:AvastDir 'AvastUI.exe'
$script:AvastUpd = Join-Path $script:AvastDir 'ashUpd.exe'

# $null when Avast is not installed.
function Get-VivacAvastStatus {
    if (-not (Test-Path -LiteralPath $script:AvastUI)) { return $null }
    $a = [ordered]@{ Running = $false; Version = ''; DefsDays = $null; Firewall = $null; Shields = 'unknown'; UpToDate = $true }
    $svc = Get-Service -Name 'avast! Antivirus' -ErrorAction SilentlyContinue
    $a.Running = [bool]($svc -and $svc.Status -eq 'Running')
    try { $a.Version = [string](Get-Item -LiteralPath $script:AvastUI).VersionInfo.ProductVersion } catch { }
    $defs = Get-ChildItem -LiteralPath (Join-Path $script:AvastDir 'defs') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($defs) {
        try {
            $d = [datetime]::ParseExact($defs.Name.Substring(0, 6), 'yyMMdd', [Globalization.CultureInfo]::InvariantCulture)
            $a.DefsDays = [int][Math]::Max(0, [Math]::Floor(((Get-Date).Date - $d).TotalDays))
        } catch { }
    }
    $fw = Get-Service -Name 'avast! Firewall' -ErrorAction SilentlyContinue
    if ($fw) { $a.Firewall = [bool]($fw.Status -eq 'Running') }
    $a
}

# --------------------------------------------------------------- Malwarebytes

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
$script:MbPaid = @('trial', 'licensed', 'premium')

# ------------------------------------------------------------------- the state

# What the Security Center, Defender, the firewall, Avast and Malwarebytes
# report, and what of it needs a look. Each problem is 'alert' (the machine
# is not protected now) or 'warn' (it is, less well than it should be).
# Defender off is only an alert while no other antivirus is on: with Avast
# on, Defender stands in passive mode by Windows' own design. Nothing here
# needs elevation.
function Get-VivacSecurityStatus {
    $s = [ordered]@{
        State = 'ok'; Products = @(); Defender = $false; Passive = $false; Realtime = $false; SignatureDays = $null; ScanDays = $null
        Tamper = $false; Threats = @(); Recent = 0; Firewall = $null; FirewallBy = ''; Avast = $null; Malwarebytes = $null; Problems = @()
    }
    $problems = New-Object System.Collections.Generic.List[object]
    $s.Products = @(Get-VivacSecurityProducts)
    $others = @($s.Products | Where-Object { $_.Kind -eq 'av' -and $_.Vendor -ne 'defender' })
    $othersOn = @($others | Where-Object { $_.State -eq 'on' })

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp -and $mp.AMServiceEnabled) {
        $s.Defender = $true
        $s.Realtime = [bool]$mp.RealTimeProtectionEnabled
        $s.Passive = ([string]$mp.AMRunningMode -match 'Passive') -or (-not $s.Realtime -and $others.Count -gt 0)
        $s.SignatureDays = [int][Math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays)
        # A scan that never happened is reported as uint32's largest value.
        $ages = @(@($mp.QuickScanAge, $mp.FullScanAge) | Where-Object { $null -ne $_ -and [uint32]$_ -ne [uint32]::MaxValue })
        if ($ages.Count) { $s.ScanDays = [int]($ages | Measure-Object -Minimum).Minimum }
        $s.Tamper = [bool]$mp.IsTamperProtected
        $s.Threats = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive } | ForEach-Object { [string]$_.ThreatName })
        $since = (Get-Date).AddDays(-7)
        $s.Recent = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $since }).Count
        if ($s.Threats.Count) { $problems.Add(@('alert', (T 'security.p_threats' @($s.Threats.Count)), 'defender')) }
        if (-not $s.Realtime -and -not $s.Passive) { $problems.Add(@('alert', (T 'security.p_realtime'), 'defender')) }
        if ($s.SignatureDays -gt $script:StaleDays) { $problems.Add(@('warn', (T 'security.p_signatures' @($s.SignatureDays)), 'defender')) }
        if (-not $s.Tamper) { $problems.Add(@('warn', (T 'security.p_tamper'), 'defender')) }
    } elseif (-not $othersOn.Count) {
        $problems.Add(@('alert', (T 'security.p_no_defender'), 'defender'))
    }
    # Somebody has to watch in real time: Defender itself, or another
    # antivirus the Security Center says is on. Defender in passive mode
    # behind a paused Avast is nobody.
    if (-not $s.Realtime -and -not $othersOn.Count) { $problems.Add(@('alert', (T 'security.p_no_realtime'), 'defender')) }

    # The firewall's own COM object answers in milliseconds where
    # Get-NetFirewallProfile takes seconds. Profiles 1, 2 and 4 are domain,
    # private and public; an inbound action of 1 lets unsolicited traffic in.
    # Another firewall registered and on (Avast's) stands in for a Windows
    # profile that is off.
    $fwProducts = @($s.Products | Where-Object { $_.Kind -eq 'fw' })
    $fwOn = @($fwProducts | Where-Object { $_.State -eq 'on' })
    $s.FirewallBy = $(if ($fwOn.Count) { $fwOn[0].Name } else { 'Windows' })
    try {
        $fw = New-Object -ComObject HNetCfg.FwPolicy2
        $s.Firewall = -not @(1, 2, 4 | Where-Object { -not $fw.FirewallEnabled($_) -or $fw.DefaultInboundAction($_) -eq 1 }).Count
        if (-not $s.Firewall -and $fwOn.Count) { $s.Firewall = $true }
        if (-not $s.Firewall) { $problems.Add(@('warn', (T 'security.p_firewall'), 'firewall')) }
    } catch { }

    # Avast: its shields as it reports them to Windows, its service, its
    # definitions. Paused shields with Defender in passive mode are the alert
    # above; here they are what to look at.
    $av = Get-VivacAvastStatus
    $s.Avast = $av
    if ($av) {
        $reg = @($others | Where-Object { $_.Vendor -eq 'avast' }) | Select-Object -First 1
        if ($reg) { $av.Shields = $reg.State; $av.UpToDate = $reg.UpToDate }
        if (-not $av.Running) { $problems.Add(@('warn', (T 'security.p_avast_stopped'), 'avast')) }
        elseif ($av.Shields -eq 'snoozed') { $problems.Add(@('warn', (T 'security.p_avast_snoozed'), 'avast')) }
        elseif ($av.Shields -eq 'off') { $problems.Add(@('warn', (T 'security.p_avast_off'), 'avast')) }
        if ($av.DefsDays -gt $script:StaleDays -or -not $av.UpToDate) { $problems.Add(@('warn', (T 'security.p_avast_defs' @($(if ($null -ne $av.DefsDays) { $av.DefsDays } else { '?' }))), 'avast')) }
    }

    # Others keep protecting whatever Malwarebytes does, so nothing about it
    # is more than a warning.
    $mb = Get-VivacMalwarebytesStatus
    $s.Malwarebytes = $mb
    if ($mb) {
        $paid = $script:MbPaid -contains $mb.License
        if (-not $mb.Running) { $problems.Add(@('warn', (T 'security.p_mb_stopped'), 'malwarebytes')) }
        elseif ($paid -and $mb.LayersOn -lt $mb.Layers.Count) { $problems.Add(@('warn', (T 'security.p_mb_layers' @($mb.Layers.Count - $mb.LayersOn)), 'malwarebytes')) }
        if ($mb.License -eq 'trial' -and $null -ne $mb.LicenseDays -and $mb.LicenseDays -le $script:MbTrialWarnDays) {
            $problems.Add(@('warn', (T 'security.p_mb_trial' @([Math]::Max(0, $mb.LicenseDays))), 'malwarebytes'))
        }
        if ($mb.DbDays -gt $script:StaleDays) { $problems.Add(@('warn', (T 'security.p_mb_database' @($mb.DbDays)), 'malwarebytes')) }
    }
    $s.Problems = $problems.ToArray()
    if (@($problems | Where-Object { $_[0] -eq 'alert' }).Count) { $s.State = 'alert' }
    elseif ($problems.Count) { $s.State = 'warn' }
    $s
}

# One word per program, for the tooltip and the cards' chips.
function Get-ProductWord($s, [string]$Vendor) {
    switch ($Vendor) {
        'defender' {
            if (-not $s.Defender) { return (T 'security.off') }
            if ($s.Realtime) { return (T 'security.active') }
            if ($s.Passive) { return (T 'security.passive') }
            return (T 'security.off')
        }
        'avast' {
            $av = $s.Avast
            if (-not $av.Running) { return (T 'security.mb_stopped') }
            if ($av.Shields -eq 'on') { return (T 'security.active') }
            if ($av.Shields -eq 'snoozed') { return (T 'security.snoozed') }
            return (T 'security.off')
        }
        'malwarebytes' {
            $mb = $s.Malwarebytes
            if (-not $mb.Running) { return (T 'security.mb_stopped') }
            if ($script:MbPaid -contains $mb.License) { return (T 'security.active') }
            return (T 'security.mb_manual')
        }
    }
    ''
}

# The programs installed, in the order the cards and the tooltip show them:
# the one watching in real time first, Defender always, Malwarebytes last.
function Get-ProductList($s) {
    $list = New-Object System.Collections.Generic.List[object]
    if ($s.Avast) { $list.Add(@('avast', 'Avast One')) }
    $list.Add(@('defender', 'Microsoft Defender'))
    if ($s.Malwarebytes) { $list.Add(@('malwarebytes', 'Malwarebytes')) }
    # The comma keeps a one-product list a list: PowerShell unrolls what a
    # function returns, and a lone pair would come back as two strings.
    , $list.ToArray()
}

# What the bar draws: a state, the few words next to the shield (none when
# all is well, so it recedes like the other gauges) and the tooltip, one
# line per program with its word and the firewall's. antivirus keeps the
# shape bin/vivac-tray.ps1 -Status gave it, so the shield can stand for all.
function Get-VivacSecuritySummary {
    $s = Get-VivacSecurityStatus
    $text = ''
    $list = Get-ProductList $s
    $words = @($list | ForEach-Object { "$($_[1]): $(Get-ProductWord $s $_[0])" })
    $tip = (@($words) + @((T 'security.fw_by' @($s.FirewallBy)))) -join "`n"
    if ($s.Problems.Count) {
        $text = $s.Problems[0][1]
        $tip = (@($s.Problems | ForEach-Object { $_[1] }) -join ' - ') + "`n" + $tip
    }
    $out = [ordered]@{
        state = $s.State; text = $text; tip = $tip; defender = [bool]$s.Defender; passive = [bool]$s.Passive
        antivirus = $null; avast = $null; malwarebytes = $null
        products = @($list | ForEach-Object { [ordered]@{ name = $_[1]; state = (Get-ProductWord $s $_[0]) } })
        firewall = $s.FirewallBy
    }
    $av = $s.Avast
    if ($av) {
        $out.avast = [ordered]@{ running = $av.Running; shields = $av.Shields; defsDays = $av.DefsDays; firewall = $av.Firewall }
        $out.antivirus = [ordered]@{ name = 'Avast'; running = ($av.Running -and $av.Shields -eq 'on') }
    }
    $mb = $s.Malwarebytes
    if ($mb) {
        if (-not $out.antivirus) { $out.antivirus = [ordered]@{ name = 'Malwarebytes'; running = $mb.Running } }
        $out.malwarebytes = [ordered]@{ running = $mb.Running; layers = $mb.LayersOn; of = $mb.Layers.Count; license = $mb.License; days = $mb.LicenseDays }
    }
    $out
}

# --------------------------------------------------------------- the redesign

# "today", "yesterday", "3 days ago".
function Format-Ago($Days) {
    if ($null -eq $Days) { return (T 'security.never') }
    if ($Days -le 0) { return (T 'security.ago.today') }
    if ($Days -eq 1) { return (T 'security.ago.yesterday') }
    T 'security.ago.days' @($Days)
}

# What the panel draws, apart from drawing it: the verdict, the problems with
# their shapes, and one card per thing protecting the machine (the firewall,
# then each antivirus Get-ProductList names), each with its lines, its chip
# and the buttons that belong to it. $S has the shape Get-VivacSecurityStatus
# gives; nothing here asks the machine anything.
function Get-VivacSecurityCards($S) {
    $rank = @{ ok = 0; warn = 1; alert = 2 }
    $levelOf = {
        param([string]$Card)
        $m = 'ok'
        foreach ($pr in @($S.Problems)) {
            if (@($pr).Count -ge 3 -and $pr[2] -eq $Card -and $rank[[string]$pr[0]] -gt $rank[$m]) { $m = [string]$pr[0] }
        }
        $m
    }
    $card = {
        param($Id, $Icon, $Name, $Lines, $Level, $Chip, $Buttons)
        [pscustomobject]@{ Id = $Id; Icon = $Icon; Name = $Name; Lines = @($Lines); Level = $Level; Chip = $Chip; Buttons = @($Buttons) }
    }
    $cards = New-Object System.Collections.Generic.List[object]

    # The firewall: Windows' own, or the one registered and on in its place.
    $by = ''
    if ($S.PSObject.Properties['FirewallBy']) { $by = [string]$S.FirewallBy }
    if ($null -eq $S.Firewall) {
        $cards.Add((& $card 'firewall' 'flame' (T 'security.fw_name') @(T 'security.fw_unknown') 'ok' @('plain', (T 'security.badge.unknown')) @()))
    } elseif ($S.Firewall) {
        $line = T 'security.fw_on'
        if ($by -and $by -ne 'Windows') { $line = T 'security.fw_by' @($by) }
        $cards.Add((& $card 'firewall' 'flame' (T 'security.fw_name') @($line) 'ok' @('ok', (T 'security.badge.on')) @()))
    } else {
        $cards.Add((& $card 'firewall' 'flame' (T 'security.fw_name') @(T 'security.fw_open') (& $levelOf 'firewall') @('warn', (T 'security.badge.review')) @()))
    }

    # The antivirus, in the order the surface lists them.
    $avName = ''
    if ($S.Avast) { $avName = 'Avast One' }
    $passive = $false
    if ($S.PSObject.Properties['Passive']) { $passive = [bool]$S.Passive }
    foreach ($vendor in @('avast', 'defender', 'malwarebytes')) {
        if ($vendor -eq 'avast' -and $S.Avast) {
            $av = $S.Avast
            $lvl = & $levelOf 'avast'
            $word = if (-not $av.Running) { T 'security.mb_stopped' } elseif ($av.Shields -eq 'on') { T 'security.active' } elseif ($av.Shields -eq 'snoozed') { T 'security.snoozed' } else { T 'security.off' }
            $svc = if ($av.Running) { T 'security.mb_running' } else { T 'security.mb_stopped' }
            $lines = @("$(T 'security.shields'): $word", "$(T 'security.mb_service') $svc - v$($av.Version)", "$(T 'security.defs'): $(Format-Ago $av.DefsDays)")
            if ($null -ne $av.Firewall) { $lines += "$(T 'security.avast_firewall'): $(if ($av.Firewall) { T 'security.on' } else { T 'security.off' })" }
            $kind = $lvl
            if ($lvl -eq 'ok' -and ($av.Shields -ne 'on' -or -not $av.Running)) { $kind = 'warn' }
            $cards.Add((& $card 'avast' 'shield' 'Avast One' $lines $lvl @($kind, $word) @('avast', 'avast_update')))
        }
        elseif ($vendor -eq 'defender') {
            $lvl = & $levelOf 'defender'
            if (-not $S.Defender) {
                $chip = @('alert', (T 'security.badge.off'))
                if ($S.Products -and @($S.Products | Where-Object { $_.Kind -eq 'av' -and $_.Vendor -ne 'defender' -and $_.State -eq 'on' }).Count) { $chip = @('plain', (T 'security.passive')) }
                $cards.Add((& $card 'defender' 'shield' 'Microsoft Defender' @(T 'security.p_no_defender') $lvl $chip @('history')))
                continue
            }
            $lines = @()
            if ($null -eq $S.ScanDays) { $lines += T 'security.line_scan_never' } else { $lines += T 'security.line_scan' @((Format-Ago $S.ScanDays)) }
            $lines += T 'security.line_sig' @((Format-Ago $S.SignatureDays))
            if ($passive -and -not $S.Realtime) {
                $lines += T 'security.passive_detail' @($(if ($avName) { $avName } else { 'Windows' }))
                $chip = @('plain', (T 'security.passive'))
            } else {
                if (-not $S.Realtime) { $lines += T 'security.line_realtime_off' }
                if (-not $S.Realtime) { $chip = @('alert', (T 'security.badge.off')) }
                elseif ($lvl -eq 'ok') { $chip = @('ok', (T 'security.badge.on')) }
                else { $chip = @($lvl, (T 'security.badge.review')) }
            }
            if (@($S.Threats).Count) { $lines += T 'security.line_threats' @((@($S.Threats) -join ', ')) }
            elseif ($S.Recent) { $lines += T 'security.line_recent' @($S.Recent) }
            $cards.Add((& $card 'defender' 'shield' 'Microsoft Defender' $lines $lvl $chip @('scan', 'update', 'history', 'windows')))
        }
        elseif ($vendor -eq 'malwarebytes' -and $S.Malwarebytes) {
            $mb = $S.Malwarebytes
            $lvl = & $levelOf 'malwarebytes'
            $svc = if ($mb.Running) { T 'security.mb_running' } else { T 'security.mb_stopped' }
            $lines = @("$(T 'security.mb_service') $svc - v$($mb.Version)")
            $paid = @('trial', 'licensed', 'premium') -contains $mb.License
            if ($paid) { $lines += "$(T 'security.realtime'): $(T 'security.mb_layers' @($mb.LayersOn, $mb.Layers.Count))" }
            else { $lines += "$(T 'security.realtime'): $(T 'security.mb_manual')" }
            if ($null -eq $mb.ScanDays) { $lines += T 'security.line_scan_never' }
            elseif ($mb.ScanThreats) { $lines += T 'security.line_scan' @((T 'security.mb_scan_found' @((Format-Ago $mb.ScanDays), $mb.ScanThreats))) }
            else { $lines += T 'security.line_scan' @((T 'security.mb_scan_clean' @((Format-Ago $mb.ScanDays)))) }
            $lines += "$(T 'security.mb_database'): $(Format-Ago $mb.DbDays)"
            if ($mb.License -eq 'trial' -and $null -ne $mb.LicenseDays) { $lines += "$(T 'security.mb_license'): $(T 'security.mb_lic_trial' @([Math]::Max(0, $mb.LicenseDays)))" }
            if (-not $mb.Running) { $chip = @('warn', (T 'security.mb_stopped')) }
            elseif ($lvl -eq 'ok') { $chip = @($(if ($paid) { 'ok' } else { 'plain' }), (Get-ProductWord $S 'malwarebytes')) }
            else { $chip = @($lvl, (T 'security.badge.review')) }
            $cards.Add((& $card 'malwarebytes' 'shield' 'Malwarebytes' $lines $lvl $chip @('open')))
        }
    }

    $issues = @($S.Problems | ForEach-Object { [pscustomobject]@{ Level = [string]$_[0]; Text = [string]$_[1] } })
    if ($issues.Count -eq 1) { $caption = T 'security.hero.issue_one' } elseif ($issues.Count) { $caption = T 'security.hero.issues' @($issues.Count) } else { $caption = T 'security.sub.ok' }
    $sub = if ($issues.Count) { T 'security.sub.issues' @($issues.Count) } else { T 'security.sub.ok' }
    [pscustomobject]@{
        Level = [string]$S.State; Title = (T "security.hero.$($S.State)"); Caption = $caption; Subtitle = $sub
        Issues = $issues; Cards = $cards.ToArray()
    }
}

# The audit script in a terminal tab of its own, left open to be read.
function Start-VivacAudit {
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\security-audit.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return $false }
    $cmd = "`"& '$script'`""
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        Start-Process wt.exe -ArgumentList @('-w', '0', 'new-tab', '--title', '"vivac audit"', 'powershell.exe', '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    } else {
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    }
    $true
}

function Get-SecurityCardXaml($t, $Card, [string[]]$Buttons) {
    $lines = -join @($Card.Lines | ForEach-Object { "<TextBlock Text=`"$(ConvertTo-XmlText $_)`" FontSize=`"12`" TextWrapping=`"Wrap`" Foreground=`"#$($t.textSecondary)`"/>" })
    $tip = { param($key) "Width=`"34`" ToolTip=`"$(ConvertTo-XmlText (T $key))`"" }
    $btnDef = @{
        scan         = @('BtnScan', (T 'security.btn_scan'), 'search', 'primary')
        update       = @('BtnUpdate', (T 'security.btn_update'), 'refresh', 'neutral')
        history      = @('BtnHistory', '', 'history', 'neutral', (& $tip 'security.btn_history'))
        windows      = @('BtnWindows', '', 'external', 'neutral', (& $tip 'security.windows'))
        open         = @('BtnMb', (T 'security.btn_open'), 'external', 'neutral')
        avast        = @('BtnAvast', (T 'security.btn_open_avast'), 'external', 'neutral')
        avast_update = @('BtnAvastUpdate', (T 'security.btn_avast_update'), 'refresh', 'neutral')
    }
    $buttonsXaml = ''
    if ($Buttons.Count) {
        $bs = foreach ($b in $Buttons) { $d = $btnDef[$b]; $more = ''; if ($d.Count -gt 4) { $more = $d[4] }; Get-PanelButtonXaml $t $d[0] $d[1] $d[2] $d[3] 34 "Margin=`"0,0,8,6`" $more" }
        $buttonsXaml = "<WrapPanel Margin=`"0,12,0,0`">$(-join $bs)</WrapPanel>"
    }
    $content = @"
<StackPanel>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    $(Get-PanelTileXaml $t $Card.Icon)
    <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
      <TextBlock Text="$(ConvertTo-XmlText $Card.Name)" FontSize="14" FontWeight="Bold" Foreground="#$($t.text)" TextTrimming="CharacterEllipsis"/>
      $lines
    </StackPanel>
    <Grid Grid.Column="2" VerticalAlignment="Top">$(Get-PanelChipXaml $t $Card.Chip[0] $Card.Chip[1])</Grid>
  </Grid>
  $buttonsXaml
</StackPanel>
"@
    Get-PanelCardXaml $t $content $Card.Level '0,8,0,0'
}

function Show-Security([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'security' }
    $surfaceName = 'security'
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $s = Get-VivacSecurityStatus
    $m = Get-VivacSecurityCards $s

    # The verdict: a shield in the level's colour, the state in words, and
    # every problem with a shape of its own (never colour alone).
    $tone = $t.success; $soft = $t.successSoft; $text = $t.successText; $shield = 'shieldok'
    if ($m.Level -ne 'ok') { $tone = $t.alert; $soft = $t.alertSoft; $text = $t.alertText; $shield = 'shieldbang' }
    $issues = ''
    if ($m.Issues.Count) {
        $rows = foreach ($i in $m.Issues) {
            $icon = 'warn'; if ($i.Level -eq 'alert') { $icon = 'cross' }
            "<StackPanel Orientation=`"Horizontal`" Height=`"26`"><Grid VerticalAlignment=`"Center`">$(Get-PanelIconXaml $icon 14 $t.alert 2.2)</Grid><TextBlock Text=`"$(ConvertTo-XmlText $i.Text)`" Margin=`"10,0,0,0`" FontSize=`"13`" VerticalAlignment=`"Center`" Foreground=`"#$($t.text)`"/></StackPanel>"
        }
        $issues = "<Border BorderBrush=`"#$($t.line)`" BorderThickness=`"0,1,0,0`" Margin=`"0,10,0,0`" Padding=`"0,8,0,0`"><StackPanel>$(-join $rows)</StackPanel></Border>"
    }
    $hero = @"
<Border Background="#$($t.surface)" CornerRadius="12" Padding="16" BorderThickness="1" BorderBrush="#$tone">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border Width="72" Height="72" CornerRadius="20" Background="#$soft" BorderBrush="#$tone" BorderThickness="2">
        <Grid HorizontalAlignment="Center" VerticalAlignment="Center">$(Get-PanelIconXaml $shield 42 $text 1.8)</Grid>
      </Border>
      <StackPanel Margin="16,0,0,0" VerticalAlignment="Center" MaxWidth="300">
        <TextBlock Text="$(ConvertTo-XmlText $m.Title)" FontSize="22" FontWeight="Bold" TextWrapping="Wrap" Foreground="#$($t.text)"/>
        <TextBlock Text="$(ConvertTo-XmlText $m.Caption)" FontSize="12" Margin="0,3,0,0" Foreground="#$($t.textSecondary)"/>
      </StackPanel>
    </StackPanel>
    $issues
  </StackPanel>
</Border>
"@
    # Avast's definitions update is its own tool; without it no button.
    $hasAvastUpd = Test-Path -LiteralPath $script:AvastUpd
    $cardsXaml = { param($Cards) -join @($Cards | ForEach-Object { Get-SecurityCardXaml $t $_ @($_.Buttons | Where-Object { $_ -ne 'avast_update' -or $hasAvastUpd }) }) }
    $fw = @($m.Cards | Where-Object { $_.Id -eq 'firewall' })
    $av = @($m.Cards | Where-Object { $_.Id -ne 'firewall' })
    $audit = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\security-audit.ps1')
    $auditSub = T 'security.audit_sub'
    if (-not $audit) { $auditSub = T 'security.audit_missing' }
    $auditContent = @"
<StackPanel>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    $(Get-PanelTileXaml $t 'search')
    <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="$(ConvertTo-XmlText (T 'security.audit_name'))" FontSize="14" FontWeight="Bold" Foreground="#$($t.text)"/>
      <TextBlock Text="$(ConvertTo-XmlText $auditSub)" FontSize="12" TextWrapping="Wrap" Foreground="#$($t.textSecondary)"/>
      <StackPanel Orientation="Horizontal" Margin="0,2,0,0"><Grid VerticalAlignment="Center">$(Get-PanelIconXaml 'lock' 12 $t.textSecondary)</Grid><TextBlock Text="$(ConvertTo-XmlText (T 'security.audit_admin'))" Margin="6,0,0,0" FontSize="12" TextWrapping="Wrap" MaxWidth="330" Foreground="#$($t.textSecondary)"/></StackPanel>
    </StackPanel>
  </Grid>
  <StackPanel Orientation="Horizontal" Margin="0,12,0,0">$(Get-PanelButtonXaml $t 'BtnAudit' (T 'security.btn_audit') 'play' 'neutral' 34 'Margin="0,0,8,0"')</StackPanel>
</StackPanel>
"@
    $body = @"
<ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,-8,0">
  <StackPanel Margin="0,0,8,0">
    $hero
    <Grid Margin="0,10,0,0">$(Get-PanelSectionXaml $t (T 'security.section.firewall'))</Grid>
    $(& $cardsXaml $fw)
    <Grid Margin="0,10,0,0">$(Get-PanelSectionXaml $t (T 'security.section.antivirus'))</Grid>
    $(& $cardsXaml $av)
    <Grid Margin="0,10,0,0">$(Get-PanelSectionXaml $t (T 'security.section.audit') (T 'security.on_demand'))</Grid>
    $(Get-PanelCardXaml $t $auditContent 'ok' '0,8,0,0')
  </StackPanel>
</ScrollViewer>
"@
    $hints = @(@('Tab', (T 'security.key.move')), @('Enter', (T 'security.key.activate')), @('Esc', (T 'security.key.close')))
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - security' 486 (Get-KitPanelXamlV2 $t (Get-KitGlyph 0xEA18) (T 'security.title') $body $hints))
    Add-KitDrawResources $window $p
    Set-KitDropDown $window
    $window.FindName('Subtitle').Text = $m.Subtitle

    # Scans and updates run in a process of their own and report back with a
    # vivac notification, so closing this window does not stop them.
    # Malwarebytes' command line needs elevation and documents no scan for
    # this edition, so it is opened for its own window to scan; Avast's
    # definitions update is its own ashUpd, silent, and its scans its window.
    $wire = {
        param([string]$Name, [scriptblock]$Action)
        $b = $window.FindName($Name)
        if ($b) { $b.Add_Click({ $window.Close(); & $Action }.GetNewClosure()) }
    }
    & $wire 'BtnScan' { Invoke-Detached $script:Helper @('-Scan') }
    & $wire 'BtnUpdate' { Invoke-Detached $script:Helper @('-Update') }
    & $wire 'BtnHistory' { Start-Process 'windowsdefender://threat' }
    & $wire 'BtnWindows' { Start-Process 'windowsdefender:' }
    & $wire 'BtnMb' { Start-Process -FilePath $script:MbExe }
    & $wire 'BtnAvast' { Start-Process -FilePath $script:AvastUI -ArgumentList '/gui' }
    & $wire 'BtnAvastUpdate' { Start-Process -FilePath $script:AvastUpd -ArgumentList 'vps' -WindowStyle Hidden }
    & $wire 'BtnAudit' { [void](Start-VivacAudit) }
    if (-not $audit) { $window.FindName('BtnAudit').IsEnabled = $false }

    $window.Add_PreviewKeyDown({
            param($sender, $e)
            if ([string]$e.Key -eq 'Escape') { $window.Close(); $e.Handled = $true }
        })
    # The first button has the focus ring, as in the design.
    $window.Add_Loaded({
            foreach ($n in 'BtnScan', 'BtnAvast', 'BtnMb', 'BtnAudit') {
                $b = $window.FindName($n)
                if ($b -and $b.IsEnabled) { [void]$b.Focus(); break }
            }
        })
    if ($NoShow) { return $window }
    if ($Registry) { $Registry[$surfaceName] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Get-VivacSecurityProducts, Get-VivacSecurityStatus, Get-VivacAvastStatus, Get-VivacMalwarebytesStatus, Get-VivacSecuritySummary, Get-VivacSecurityCards, Show-Security
