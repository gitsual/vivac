# The redesigned panels' shared pieces and the logic of the security panel:
# tokens derived from a palette, stroke icons turned into WPF paths, the
# cards the security panel draws from a status, and each panel building.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$profileDir = New-TempProfile
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\PanelKit.psm1') -Force
Import-Module (Join-Path $root 'lib\Security.psm1') -Force
[void](Import-VivacStrings 'en')

Case 'tokens derive the soft and text tones as the GTK kit does' {
    $p = @{ COLOR_BG = '283536'; COLOR_SURFACE = '302B21'; COLOR_SURFACE_ALT = '484236'; COLOR_ACCENT = 'AAA875'; COLOR_FG = 'C9C9C8'
        COLOR_FG_DIM = 'B9B9B9'; COLOR_MUTED = '979367'; COLOR_URGENT = 'BD6161'; COLOR_INFO = '6CA4B1'; COLOR_OK = '55A185'; COLOR_BORDER_INACTIVE = '544E40' }
    $t = Get-PanelTokens $p
    Assert-Equal 'C28E8D' $t.alertText
    Assert-Equal '433D3E' $t.alertSoft
    Assert-Equal '304844' $t.successSoft
    Assert-Equal '34494C' $t.infoSoft
    Assert-Equal 'BFBE98' $t.focusRing
    Assert-Equal '283536' $t.actionText
    Assert-Equal 'AAA875' $t.actionFill
}
Case 'an icon is a viewbox of paths; rect and circle become arcs' {
    $x = Get-PanelIconXaml 'search' 14 'FFFFFF'
    $el = ConvertTo-PanelElement $x
    Assert-True ($el -is [Windows.Controls.Viewbox]) 'a viewbox'
    Assert-True ($x -match 'A6.5,6.5') 'the circle is two arcs'
    $x = Get-PanelIconXaml 'lock' 12 'FFFFFF'
    Assert-True ($x -match 'M7,11 H17') 'the rounded rect starts after its corner'
    [void](ConvertTo-PanelElement (Get-PanelIconXaml 'calendar' 12 'FFFFFF'))
    Assert-Throws { Get-PanelIconXaml 'nope' 12 'FFFFFF' } 'no panel icon'
}
Case 'a button with its focus ring, a chip and a card parse' {
    $t = Get-PanelTokens @{ COLOR_BG = '101010'; COLOR_SURFACE = '202020'; COLOR_SURFACE_ALT = '303030'; COLOR_ACCENT = 'C0A060'; COLOR_FG = 'E0E0E0'; COLOR_FG_DIM = 'B0B0B0'; COLOR_MUTED = '888888'; COLOR_URGENT = 'C05050'; COLOR_INFO = '5090C0'; COLOR_OK = '50A080' }
    $b = ConvertTo-PanelElement (Get-PanelButtonXaml $t 'B' 'Go' 'play' 'primary')
    Assert-True ($b -is [Windows.Controls.Button]) 'a button'
    foreach ($k in 'ok', 'warn', 'alert', 'plain') { [void](ConvertTo-PanelElement (Get-PanelChipXaml $t $k 'x')) }
    [void](ConvertTo-PanelElement (Get-PanelCardXaml $t '<TextBlock Text="a"/>' 'warn'))
}

# A status the way Get-VivacSecurityStatus shapes it.
function New-FakeStatus([hashtable]$Over = @{}) {
    $s = [ordered]@{ State = 'ok'; Defender = $true; Realtime = $true; SignatureDays = 0; ScanDays = 1; Tamper = $true; Threats = @(); Recent = 0
        Firewall = $true; FirewallBy = 'Windows'; Passive = $false; Products = @(); Avast = $null; Malwarebytes = $null; Problems = @() }
    foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
    [pscustomobject]$s
}
Case 'a clean machine has two cards, both ok, and no issues' {
    $m = Get-VivacSecurityCards (New-FakeStatus)
    Assert-Equal 'ok' $m.Level
    Assert-Equal 0 $m.Issues.Count
    Assert-Equal 'firewall,defender' (($m.Cards | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal 'ok' $m.Cards[1].Chip[0]
    Assert-Equal 'scan,update,history,windows' ($m.Cards[1].Buttons -join ',')
    Assert-Equal 'Last scan: yesterday' $m.Cards[1].Lines[0]
}
Case 'a problem tagged with a card lowers only that card' {
    $s = New-FakeStatus @{ State = 'warn'; Firewall = $false; Problems = @(, @('warn', 'firewall abierto', 'firewall')) }
    $m = Get-VivacSecurityCards $s
    Assert-Equal 'warn' $m.Cards[0].Level
    Assert-Equal 'warn' $m.Cards[0].Chip[0]
    Assert-Equal 'ok' $m.Cards[1].Level
    Assert-Equal 1 $m.Issues.Count
    Assert-Equal 'firewall abierto' $m.Issues[0].Text
    Assert-Equal '1 thing to check' $m.Caption
}
Case 'real-time protection off is an alert chip saying off; a scan that never ran says so' {
    $s = New-FakeStatus @{ State = 'alert'; Realtime = $false; ScanDays = $null; Problems = @(, @('alert', 'protection off', 'defender')) }
    $m = Get-VivacSecurityCards $s
    Assert-Equal 'alert' $m.Cards[1].Chip[0]
    Assert-Equal 'off' $m.Cards[1].Chip[1]
    Assert-Equal 'No scan has run yet' $m.Cards[1].Lines[0]
    Assert-Equal 'At risk' $m.Title
}
Case 'without Defender the card says so and offers only the history' {
    $s = New-FakeStatus @{ State = 'alert'; Defender = $false; Problems = @(, @('alert', 'Defender no responde', 'defender')) }
    $m = Get-VivacSecurityCards $s
    Assert-Equal 'alert' $m.Cards[1].Level
    Assert-Equal 'history' ($m.Cards[1].Buttons -join ',')
}
Case 'Malwarebytes gets a card of its own with real lines' {
    $mb = [pscustomobject]@{ Running = $true; Version = '5.1'; Layers = @(1, 2, 3, 4); LayersOn = 3; ScanDays = 2; ScanThreats = 0; DbDays = 0; License = 'trial'; LicenseDays = 9 }
    $m = Get-VivacSecurityCards (New-FakeStatus @{ Malwarebytes = $mb })
    $c = $m.Cards[2]
    Assert-Equal 'malwarebytes' $c.Id
    Assert-Equal 'open' ($c.Buttons -join ',')
    Assert-True ($c.Lines -contains 'Last scan: 2 days ago, clean') 'the last scan'
    Assert-True (@($c.Lines | Where-Object { $_ -match 'Licen[cs]e: ' }).Count -eq 1) 'the trial'
}
Case 'Avast on and Defender passive: Avast first, Defender says it is standing by' {
    $av = [pscustomobject]@{ Running = $true; Version = '25.1'; DefsDays = 0; Firewall = $true; Shields = 'on'; UpToDate = $true }
    $s = New-FakeStatus @{ Realtime = $false; Passive = $true; Avast = $av; FirewallBy = 'Avast Firewall'
        Products = @([ordered]@{ Kind = 'av'; Name = 'Avast Antivirus'; Vendor = 'avast'; State = 'on'; UpToDate = $true }) }
    $m = Get-VivacSecurityCards $s
    Assert-Equal 'firewall,avast,defender' (($m.Cards | ForEach-Object { $_.Id }) -join ',')
    Assert-Equal 'Firewall: Avast Firewall' $m.Cards[0].Lines[0]
    Assert-Equal 'ok' $m.Cards[1].Chip[0]
    Assert-Equal 'avast,avast_update' ($m.Cards[1].Buttons -join ',')
    Assert-Equal 'plain' $m.Cards[2].Chip[0]
    Assert-Equal 'passive' $m.Cards[2].Chip[1]
    Assert-True (@($m.Cards[2].Lines | Where-Object { $_ -match 'Avast One' }).Count -eq 1) 'who watches'
}
Case 'paused Avast shields are a warning on the Avast card only' {
    $av = [pscustomobject]@{ Running = $true; Version = '25.1'; DefsDays = 0; Firewall = $null; Shields = 'snoozed'; UpToDate = $true }
    $s = New-FakeStatus @{ State = 'warn'; Avast = $av; Problems = @(, @('warn', 'avast paused', 'avast')) }
    $m = Get-VivacSecurityCards $s
    Assert-Equal 'warn' $m.Cards[1].Level
    Assert-Equal 'warn' $m.Cards[1].Chip[0]
    Assert-Equal 'paused' $m.Cards[1].Chip[1]
    Assert-Equal 'ok' $m.Cards[2].Level
}
Case 'the security panel builds, with its buttons, in the worn theme' {
    $w = Show-Security -NoShow
    Assert-True ($w -is [Windows.Window]) 'a window'
    Assert-True ($w.Title -match '^vivac') 'titled vivac'
    Assert-True ($null -ne $w.FindName('BtnAudit')) 'the audit button'
    Assert-True ($w.FindName('Subtitle').Text.Length -gt 0) 'a subtitle'
    $w.Close()
}
Import-Module (Join-Path $root 'lib\Updates.psm1') -Force
[void](Import-VivacStrings 'en')
Case 'the updates model counts origins and lists Windows Update first, five at most' {
    $wu = @([pscustomobject]@{ Title = 'Cumulative update'; KB = 'KB5000'; Size = 52428800; Downloaded = $false; Categories = '' })
    $apps = 1..7 | ForEach-Object { [pscustomobject]@{ Name = "App$_"; Id = "Pub.App$_"; Version = '1.0'; Available = '2.0'; Source = 'winget' } }
    $m = Get-VivacUpdatesModel $wu $apps
    Assert-Equal 8 $m.Total
    Assert-Equal 'windows:1,winget:7' (($m.Groups | ForEach-Object { "$($_.Origin):$($_.Count)" }) -join ',')
    Assert-Equal 5 $m.First.Count
    Assert-Equal 'windows' $m.First[0].Origin
    Assert-Equal 'KB5000  -  50 MB' $m.First[0].Sub
    Assert-Equal 'Pub.App1' $m.First[1].Id
    Assert-True $m.More 'more than shown'
}
Case 'nothing pending is no groups and no rows' {
    $m = Get-VivacUpdatesModel @() @()
    Assert-Equal 0 $m.Total
    Assert-Equal 0 @($m.Groups).Count
    Assert-True (-not $m.More) 'nothing more'
}
Case 'the last check is said in minutes, hours or days' {
    $now = Get-Date '2026-11-23 12:00'
    Assert-Equal 'Checked just now' (Format-UpdatesAgo $now.AddSeconds(-20) $now)
    Assert-Equal 'Checked 2 min ago' (Format-UpdatesAgo $now.AddMinutes(-2) $now)
    Assert-Equal 'Checked 3 h ago' (Format-UpdatesAgo $now.AddHours(-3) $now)
    Assert-Equal 'Checked 4 days ago' (Format-UpdatesAgo $now.AddDays(-4) $now)
}
Case 'the updates panel builds, with its refresh button' {
    $w = Show-Updates -NoShow
    Assert-True ($w -is [Windows.Window]) 'a window'
    Assert-True ($w.Title -match '^vivac') 'titled vivac'
    Assert-Equal 1 $w.FindName('HeaderRight').Children.Count 'the refresh button'
    $w.Close()
}
Complete-Cases
