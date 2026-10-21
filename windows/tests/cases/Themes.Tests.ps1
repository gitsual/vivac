# The catalogue and its doctrine, as in the source: a palette is exactly the
# thirteen tokens, every colour comes from the corpus, a declared distance is
# the distance the matrix gives, and an ornament is earned or refused.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Desktop.psm1') -Force

$root = Get-RepoRoot
# A scratch profile: palettes made from pictures in the real one would join
# the catalogue counted below.
$scratch = New-TempProfile
$corpus = @{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $root 'data\palette-corpus.tsv'))) {
    if ($line -match '^([0-9A-F]{6})\t') { $corpus[$Matches[1]] = $true }
}

Case 'the catalogue is the default plus every file in data/themes, eight in all' {
    $names = @(Get-VivacCatalogue)
    Assert-Equal 'bad-romance' $names[0]
    Assert-Equal 8 $names.Count
}
foreach ($name in Get-VivacCatalogue) {
    Case "${name} loads: thirteen tokens, bare upper-case hex" {
        $t = Read-VivacTheme $name
        Assert-Equal 13 $t.Tokens.Count
    }
    Case "${name} uses only colours from the corpus" {
        $t = Read-VivacTheme $name
        $foreign = @($t.Tokens.Keys | Where-Object { -not $corpus.ContainsKey($t.Tokens[$_]) } | ForEach-Object { "$_=$($t.Tokens[$_])" })
        Assert-True (-not $foreign.Count) "not in data/palette-corpus.tsv: $($foreign -join ', ')"
    }
    Case "${name} declares a title and an essence" {
        $t = Read-VivacTheme $name
        Assert-True ($t.Meta.Contains('title') -and $t.Meta.Contains('essence'))
    }
    Case "${name}: a declared distance is the matrix's distance, and the verdict follows it" {
        $t = Read-VivacTheme $name
        if (-not $t.Meta.Contains('distance')) { return }
        $d = Get-RootDistance $t.Meta['dominant'] $t.Meta['accent']
        Assert-Equal $d $t.Meta['distance'] "$name declares distance"
        $verdict = 'rupture'
        if ($d -le 2) { $verdict = 'affinity' } elseif ($d -le 4) { $verdict = 'tension' }
        Assert-Equal $verdict $t.Meta['verdict'] "$name verdict"
    }
    Case "${name}: an ornament claim is earned, and the wallpaper SVG is well-formed" {
        $t = Read-VivacTheme $name
        [void](Get-VivacOrnament $t)
        [xml]$svg = Get-VivacWallpaperSvg $t
        Assert-Equal 'svg' $svg.DocumentElement.LocalName
    }
}
Case 'exactly the themes that earned one carry an ornament' {
    $with = @(Get-VivacCatalogue | Where-Object { Get-VivacOrnament (Read-VivacTheme $_) })
    Assert-Equal @('cosmos', 'persephone') $with
}
Case 'an unearned ornament claim fails instead of being dropped' {
    $t = Read-VivacTheme 'metropolis'
    $t.Meta['ornament'] = 'filigree'
    Assert-Throws { Get-VivacOrnament $t } 'without an affinity'
}
Case 'a claimed aesthetic must carry its canonical colours' {
    $t = Read-VivacTheme 'cosmos'
    $t.Tokens['COLOR_ACCENT'] = 'E1777D'
    Assert-Throws { Get-VivacOrnament $t } 'without an affinity'
}
Case 'a malformed palette is refused when read' {
    $dir = Join-Path $root 'data\themes'
    $bad = Join-Path $dir 'zz-test-broken.conf'
    [IO.File]::WriteAllText($bad, "COLOR_BG=2d1f2d`n")
    try { Assert-Throws { Read-VivacTheme 'zz-test-broken' } 'not bare upper-case' } finally { Remove-Item -LiteralPath $bad -Force }
}
Remove-TempProfile $scratch
Complete-Cases
