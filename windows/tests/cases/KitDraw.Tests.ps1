# The drawn half of the WPF kit (lib/KitDraw.psm1): tokens, chrome, styles and
# the pieces, built without a theme or a window on screen.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\KitDraw.psm1') -Force

$p = @{ COLOR_BG = '283536'; COLOR_FG = 'C9C9C8'; COLOR_FG_DIM = 'B9B9B9'; COLOR_SURFACE = '302B21'; COLOR_SURFACE_ALT = '484236'
    COLOR_ACCENT = 'AAA875'; COLOR_MUTED = '979367'; COLOR_URGENT = 'BD6161'; COLOR_INFO = '6CA4B1'; COLOR_OK = '55A185'; COLOR_BORDER_INACTIVE = '544E40' }
$t = Get-KitTokens $p

Case 'tokens carry the canvas names, and the action colours follow the accent and the base' {
    Assert-Equal 'AAA875' $t['accent']
    Assert-Equal 'C9C9C8' $t['text']
    Assert-Equal 'BD6161' $t['alert']
    Assert-Equal $t['accent'] $t['actionFill']
    Assert-Equal $t['bg'] $t['actionText']
    Assert-Equal 'BFBE98' $t['focusRing'] 'the accent a quarter of the way to white'
    $bare = Get-KitTokens @{}
    Assert-Equal 'C05050' $bare['alert'] 'a theme lacking a token falls back'
}
Case 'the styles parse and the fader tops out where asked' {
    foreach ($max in 100, 150) {
        $d = [Windows.Markup.XamlReader]::Parse((Get-KitDrawResourcesXaml $t $max))
        foreach ($k in 'KitFader', 'KitChip', 'KitChipSel', 'KitChipOn', 'KitMute', 'KitMuteOn', 'KitAction', 'KitActionPrimary', 'KitActionDanger', 'KitOutline') {
            Assert-True $d.Contains($k) "$k at $max"
        }
    }
}
Case 'a panel in the redesigned chrome has the named parts a caller reaches' {
    $xaml = Get-KitWindowXamlV2 $t 'vivac - test' 440 (Get-KitPanelXamlV2 $t ([string][char]0xE767) 'Test' '<TextBlock x:Name="Inside" Text="x"/>' @(@('Esc', 'close')))
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    foreach ($n in 'Subtitle', 'HeaderRight', 'HeadGlyph', 'Foot', 'Inside') { Assert-True ($null -ne $w.FindName($n)) "no $n" }
    Assert-Equal 'vivac - test' $w.Title
    Assert-True $w.Topmost
}
Case 'a fader, a chip and a ruler build from the styles' {
    $w = [Windows.Markup.XamlReader]::Parse((Get-KitWindowXamlV2 $t 'vivac - test' 300 '<Grid/>'))
    Add-KitDrawResources $w $p 150
    $f = New-KitFader $w $t 120 150 $false
    Assert-Equal 150 $f.Maximum
    Assert-Equal 120 $f.Value
    Assert-Equal 150 (New-KitFader $w $t 400 150).Value 'a value past the top is held at it'
    $on = New-KitChip $w $t 'Todo' '7' -Selected
    $off = New-KitChip $w $t 'Texto' '2'
    Assert-True ($on.Style -ne $off.Style) 'the selected chip has its own look'
    Assert-Equal '7' $on.Tag.Count.Text
    Assert-Equal 5 @((New-KitRuler $t @(0, 25, 50, 75, 100)).Children).Count
}
Case 'a notch bar lights its share, in alert past the danger line' {
    $b = New-KitNotchBar $t 20 8
    Assert-Equal 10 (Set-KitNotchBar $b 0.5) 'half of twenty'
    Assert-Equal 0 (Set-KitNotchBar $b 0.5 $true) 'muted lights none'
    Assert-Equal 20 (Set-KitNotchBar $b 1.5) 'a fraction past 1 is held at 1'
    [void](Set-KitNotchBar $b 1.0 $false 0.75)
    $alert = @($b.Tag.Cells | Where-Object { $_.Background.Color.ToString() -eq "#FF$($t['alert'])" }).Count
    Assert-Equal 5 $alert 'the last quarter is past 0.75'
}
Case 'a ring draws its arc from twelve o''clock, clockwise' {
    $r = New-KitRing $t 100 10
    Set-KitRing $r 0.25
    $a = $r.Tag.Arc
    Assert-True ([Math]::Abs($a.Point.X - 95) -lt 0.001 -and [Math]::Abs($a.Point.Y - 50) -lt 0.001) 'a quarter ends at three o''clock'
    Assert-Equal $false $a.IsLargeArc
    Set-KitRing $r 0.75
    Assert-Equal $true $r.Tag.Arc.IsLargeArc 'past half it is the long way round'
    Set-KitRing $r 0
    Assert-Equal 'Collapsed' ([string]$r.Tag.Path.Visibility) 'nothing to draw at zero'
    Set-KitRing $r 1
    Assert-Equal 'Visible' ([string]$r.Tag.Path.Visibility) 'a whole turn still draws'
    Set-KitRing $r 0.5 'alert'
    Assert-Equal "#FF$($t['alert'])" $r.Tag.Path.Stroke.Color.ToString()
}
Complete-Cases
