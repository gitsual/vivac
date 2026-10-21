# A palette from a picture: the same picture makes the same file as on Linux
# (shared/fixtures/theme-from-image), and whatever the picture, the palette
# keeps every rule the shipped eight keep: corpus colours only, the contrast
# floors, the separations, a declared distance that is the matrix's, and no
# rupture. Made palettes live outside the checkout and join the catalogue.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Desktop.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Picture.psm1') -Force

$root = Get-RepoRoot
$fixtures = Join-Path (Split-Path -Parent $root) 'shared\fixtures\theme-from-image'

function Read-Rows([string]$File) {
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $root "data\$File"))) {
        if ($line -match '^\s*(#|$)') { continue }
        , @($line -split "`t")
    }
}
$corpus = @{}
foreach ($f in Read-Rows 'palette-corpus.tsv') { if (-not $corpus.ContainsKey($f[0])) { $corpus[$f[0]] = $f[2] } }
$roots = @{}
foreach ($f in Read-Rows 'corpus-roots.tsv') { $roots[$f[0]] = $f[1] }

# The gate's own measures, written again here so the test does not grade the
# code with the code's own arithmetic.
function Get-Lum([string]$Hex) {
    $sum = 0.0
    $w = 0.2126, 0.7152, 0.0722
    for ($i = 0; $i -lt 3; $i++) {
        $c = [Convert]::ToInt32($Hex.Substring($i * 2, 2), 16) / 255
        if ($c -le 0.03928) { $c = $c / 12.92 } else { $c = [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
        $sum += $w[$i] * $c
    }
    $sum
}
function Get-Ratio([string]$A, [string]$B) {
    $x = Get-Lum $A; $y = Get-Lum $B
    ([Math]::Max($x, $y) + 0.05) / ([Math]::Min($x, $y) + 0.05)
}
function Get-Redmean([string]$One, [string]$Other) {
    # Not $a and $b: variable names are case-blind, and those would be $A and $B.
    $x = 0, 2, 4 | ForEach-Object { [Convert]::ToInt32($One.Substring($_, 2), 16) }
    $y = 0, 2, 4 | ForEach-Object { [Convert]::ToInt32($Other.Substring($_, 2), 16) }
    $r = ($x[0] + $y[0]) / 2
    [Math]::Sqrt((2 + $r / 256) * [Math]::Pow($x[0] - $y[0], 2) + 4 * [Math]::Pow($x[1] - $y[1], 2) + (2 + (255 - $r) / 256) * [Math]::Pow($x[2] - $y[2], 2))
}

# Every rule test_theme_catalogue.sh and Themes.Tests.ps1 hold the shipped
# eight to, for one palette (its tokens and its declarations).
function Assert-KeepsTheRules($Tokens, [string]$Dominant, [string]$Accent, [int]$Distance) {
    Assert-Equal 13 $Tokens.Count 'tokens'
    foreach ($key in Get-VivacTokenNames) {
        Assert-True ($Tokens[$key] -cmatch '^[0-9A-F]{6}$') "$key is not bare hex"
        Assert-True $corpus.ContainsKey($Tokens[$key]) "$key=$($Tokens[$key]) is not in the corpus"
    }
    foreach ($floor in @(@('COLOR_FG', 'COLOR_BG', 7.0), @('COLOR_FG_DIM', 'COLOR_BG', 4.5), @('COLOR_ACCENT', 'COLOR_BG', 3.0), @('TERMINAL_FG', 'TERMINAL_BG', 7.0))) {
        $r = Get-Ratio $Tokens[$floor[0]] $Tokens[$floor[1]]
        Assert-True ($r -ge $floor[2]) "$($floor[0]) is $r against $($floor[1])"
    }
    Assert-True ((Get-Redmean $Tokens['COLOR_FG_DIM'] $Tokens['COLOR_MUTED']) -ge 60) "dim text $($Tokens['COLOR_FG_DIM']) and muted $($Tokens['COLOR_MUTED']) read as one"
    Assert-True ((Get-Redmean $Tokens['COLOR_ACCENT'] $Tokens['COLOR_INFO']) -ge 60) 'accent and info read as one'
    Assert-Equal $roots[$Tokens['COLOR_BG']] $Dominant 'dominant root'
    Assert-Equal $roots[$Tokens['COLOR_ACCENT']] $Accent 'accent root'
    Assert-Equal (Get-RootDistance $Dominant $Accent) $Distance 'distance'
    Assert-True ($Distance -lt 5) "a rupture ($Distance) with no mediator"
    Assert-True ($Dominant -ne $Accent) "pairs $Dominant with itself, which the matrix does not list"
}

Case 'every ground and accent of the corpus is filed under a root' {
    $missing = @($corpus.Keys | Where-Object { @('deep', 'base', 'accent') -contains $corpus[$_] -and -not $roots.ContainsKey($_) })
    Assert-True (-not $missing.Count) "no root for: $($missing -join ', ')"
    $unknown = @($roots.Keys | Where-Object { -not $corpus.ContainsKey($_) })
    Assert-True (-not $unknown.Count) "not in the corpus: $($unknown -join ', ')"
}
Case 'the root table reads the shipped themes the way they declare themselves' {
    foreach ($name in Get-VivacCatalogue) {
        $t = Read-VivacTheme $name
        if (-not $t.Meta.Contains('dominant')) { continue }
        Assert-Equal $t.Meta['dominant'] $roots[$t.Tokens['COLOR_BG']] "$name ground"
        Assert-Equal $t.Meta['accent'] $roots[$t.Tokens['COLOR_ACCENT']] "$name accent"
    }
}

if (Test-Path -LiteralPath $fixtures) {
    foreach ($fixture in 'dusk', 'ember') {
        Case "${fixture}.png makes exactly ${fixture}.conf, the file the Linux half makes" {
            $made = New-VivacPaletteFromPicture -Image (Join-Path $fixtures "$fixture.png") -DryRun -Directory $env:TEMP
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixtures "$fixture.conf"))) $made.Text
        }
    }
} else {
    Write-Host '  SKIP  fixtures: not inside the product (no shared\)'
}

Case 'whatever the picture, the palette keeps the catalogue rules' {
    # A small linear congruential generator: the same pictures every run.
    $seed = [long]12345
    foreach ($picture in 1..12) {
        $points = New-Object int[] 600
        # Each picture leans towards one hue, with noise and a few outliers.
        $seed = ($seed * 1103515245 + 12345) % 2147483648
        $base = @((($seed -shr 16) % 256), (($seed -shr 8) % 256), ($seed % 256))
        for ($i = 0; $i -lt $points.Length; $i++) {
            $c = @()
            foreach ($k in 0..2) {
                $seed = ($seed * 1103515245 + 12345) % 2147483648
                $v = $base[$k] + (($seed -shr 16) % 81) - 40
                if ($i % 17 -eq 0) { $v = ($seed -shr 8) % 256 }
                $c += [Math]::Max(0, [Math]::Min(255, $v))
            }
            $points[$i] = ($c[0] -shl 16) -bor ($c[1] -shl 8) -bor $c[2]
        }
        $p = New-VivacPaletteFromSamples $points
        Assert-KeepsTheRules $p.Tokens $p.Dominant $p.Accent $p.Distance
    }
    # No colour at all: grey, white, black.
    foreach ($flat in 0x808080, 0xFFFFFF, 0x000000) {
        $p = New-VivacPaletteFromSamples ([int[]]@($flat) * 50)
        Assert-KeepsTheRules $p.Tokens $p.Dominant $p.Accent $p.Distance
    }
}

Case 'a name comes from the file name, or is refused' {
    Assert-Equal 'img-2024-beach' (Get-VivacPictureName 'C:\x\IMG_2024 Beach.JPG' '')
    Assert-Equal 'picture-2024' (Get-VivacPictureName 'C:\x\2024.png' '')
    Assert-Equal 'picture' (Get-VivacPictureName 'C:\x\!!!.png' '')
    Assert-Equal 'abcdefghijklmnopqrstuvwxyzabcdef' (Get-VivacPictureName 'C:\x\abcdefghijklmnopqrstuvwxyzabcdefghij.png' '')
    Assert-Equal 'my-sea' (Get-VivacPictureName 'C:\x\whatever.png' 'my-sea')
    Assert-Throws { Get-VivacPictureName 'C:\x\a.png' 'My Sea' } "'My Sea'"
}

$dir = New-TempProfile
try {
    Case 'a dry run writes nothing; a shipped name or a non-picture is refused' {
        if (-not (Test-Path -LiteralPath $fixtures)) { return }
        $made = New-VivacPaletteFromPicture -Image (Join-Path $fixtures 'dusk.png') -DryRun
        Assert-True (-not (Test-Path -LiteralPath $made.Path)) 'the dry run wrote the palette'
        Assert-True (@($made.Lines | Where-Object { $_.Contains([string][char]27 + '[48;2;37;56;80m') }).Count -ge 1) 'no truecolour swatch for the ground'
        Assert-Throws { New-VivacPaletteFromPicture -Image (Join-Path $fixtures 'dusk.png') -Name 'cosmos' } 'cosmos.*-Name'
        Assert-Throws { New-VivacPaletteFromPicture -Image (Join-Path $fixtures 'dusk.conf') } 'PNG'
    }
    Case 'a made palette joins the catalogue after the shipped eight, and wears its picture' {
        if (-not (Test-Path -LiteralPath $fixtures)) { return }
        $made = New-VivacPaletteFromPicture -Image (Join-Path $fixtures 'ember.png') -Name 'my-ember'
        Assert-Equal (Join-Path (Get-VivacPaths).Config 'themes\my-ember.conf') $made.Path
        $names = @(Get-VivacCatalogue)
        Assert-Equal 9 $names.Count
        Assert-Equal 'my-ember' $names[8]
        $t = Read-VivacTheme 'my-ember'
        Assert-Equal 'Picture' $t.Essence
        Assert-Equal (Join-Path (Get-VivacPaths).Config 'themes\my-ember.png') $t.Picture
        $wall = Get-VivacWallpaper -Theme $t -DryRun
        Assert-True ($wall.StartsWith((Get-VivacPaths).Wallpapers) -and $wall.EndsWith('.png')) "wallpaper: $wall"
        Set-VivacSetting theme 'my-ember'
        Assert-Equal 'my-ember' (Read-VivacSettings)['theme']
    }
    Case 'a palette outside the checkout that breaks the corpus rule is left out' {
        $themes = Join-Path (Get-VivacPaths).Config 'themes'
        $good = [IO.File]::ReadAllText((Join-Path $themes 'my-ember.conf'))
        [IO.File]::WriteAllText((Join-Path $themes 'off-corpus.conf'), ($good -replace 'COLOR_BG=[0-9A-F]{6}', 'COLOR_BG=123456'))
        [IO.File]::WriteAllText((Join-Path $themes 'cosmos.conf'), $good)
        [IO.File]::WriteAllText((Join-Path $themes 'far-wall.conf'), ($good -replace '@wallpaper: my-ember.png', '@wallpaper: ../../x.png'))
        $names = @(Get-VivacCatalogue)
        Assert-True ($names -notcontains 'off-corpus') 'an off-corpus palette is in the catalogue'
        Assert-True ($names -notcontains 'far-wall') 'a palette with a wallpaper elsewhere is in the catalogue'
        Assert-Equal 1 @($names | Where-Object { $_ -eq 'cosmos' }).Count
        Assert-True ((Read-VivacTheme 'cosmos').Path.StartsWith($root)) 'a shipped name means the shipped palette'
        Assert-Throws { Read-VivacTheme 'off-corpus' } 'not in the corpus'
    }
    Case 'with a shared root, a new palette goes to its themes folder, where the other system looks' {
        if (-not (Test-Path -LiteralPath $fixtures)) { return }
        $share = Join-Path $dir 'share'
        New-Item -ItemType Directory -Force -Path $share | Out-Null
        Set-VivacSetting shared_settings (Join-Path $share 'settings')
        $made = New-VivacPaletteFromPicture -Image (Join-Path $fixtures 'dusk.png')
        Assert-Equal (Join-Path $share 'themes\dusk.conf') $made.Path
        Assert-True (Test-Path -LiteralPath (Join-Path $share 'themes\dusk.png')) 'the picture did not travel with it'
        Assert-True (@(Get-VivacCatalogue) -contains 'dusk') 'the shared palette is not in the catalogue'
        # A share that is away: this system's own folder.
        Set-VivacSetting shared_settings (Join-Path $dir 'away\settings')
        Assert-Equal (Join-Path (Get-VivacPaths).Config 'themes') (Get-VivacPaletteHome)
    }
} finally {
    Remove-TempProfile $dir
}
Complete-Cases
