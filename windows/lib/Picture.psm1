# A palette from a picture, under the corpus's rules: vivac theme from-image.
#
# No colour is invented. Every role takes a colour from data/palette-corpus.tsv;
# the picture only decides which. The Linux half (linux/scripts/
# theme-from-image.py) runs the same steps with the same constants, so the same
# picture gives the same file on both systems; shared/fixtures/theme-from-image
# holds one picture and the palette both halves must make from it.
#
# The steps:
#   1. Samples: a grid of at most 64 x 64 points, the centre of each cell, read
#      straight from the decoded pixels (no resampling, which no two decoders
#      do alike). Points under half opacity are skipped.
#   2. Distance: redmean, the measure the catalogue gate already uses, kept in
#      integers (512 times its square) so both halves compare exactly.
#   3. Ground (COLOR_BG): every sample votes for the nearest dark corpus
#      colour (role deep or base); the most voted wins. If no complete palette
#      can be built on it, the next most voted is tried.
#   4. Text, then the rest, each from the corpus rows of its role, each the
#      first in its order that clears its floor against the ground (the
#      catalogue's floors: 7:1 text, 4.5:1 dim text, 3:1 accent).
#   5. The accent is the picture's most salient colour: samples vote weighted
#      by their chroma, and an accent whose root is a rupture (distance >= 5
#      in root-distance.tsv) from the ground's root is passed over, since a
#      rupture would need a mediator nobody chose; so is one of the ground's
#      own root, since a theme pairs two roots and the matrix has no such row.
#   6. Urgent, info, ok and muted keep their meaning: the corpus colour nearest
#      the shipped signal colour that clears the floor and stays apart from
#      the accent (60 for info, and for muted against dim text).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:Root = Split-Path -Parent $PSScriptRoot

$script:Grid = 64
$script:Opaque = 128
$script:TextFloor = 7.0
$script:DimFloor = 4.5
$script:MarkFloor = 3.0
# Surfaces are ground, not ink: under 3:1 against the base, and text on them
# still clears the dim-text floor.
$script:SurfaceCeiling = 3.0
# The terminal keeps a neutral ground (theme.conf says why): a deep colour
# whose channels lie within this much of each other.
$script:Neutral = 24
# The catalogue's separation of 60 (redmean), as 512 times its square.
$script:Apart = 512 * 60 * 60
$script:Rupture = 5
$script:Anchors = @{ COLOR_URGENT = 'BD6161'; COLOR_INFO = '6CA4B1'; COLOR_OK = '55A185'; COLOR_MUTED = '979367' }

# The one loop that runs thousands of times: each sample to its nearest
# candidate. In PowerShell it would take seconds; the arithmetic is the same.
if (-not ('VivacPicture' -as [type])) {
    Add-Type -TypeDefinition @'
public static class VivacPicture {
    // 512 x redmean squared, in integers: (2 + r/256, 4, 2 + (255 - r)/256) over the mean red.
    public static long D2(int a, int b) {
        long r1 = (a >> 16) & 255, g1 = (a >> 8) & 255, b1 = a & 255;
        long r2 = (b >> 16) & 255, g2 = (b >> 8) & 255, b2 = b & 255;
        return (1024 + r1 + r2) * (r1 - r2) * (r1 - r2) + 2048 * (g1 - g2) * (g1 - g2) + (1534 - r1 - r2) * (b1 - b2) * (b1 - b2);
    }
    public static int Chroma(int p) {
        int r = (p >> 16) & 255, g = (p >> 8) & 255, b = p & 255;
        int max = r > g ? (r > b ? r : b) : (g > b ? g : b);
        int min = r < g ? (r < b ? r : b) : (g < b ? g : b);
        return max - min;
    }
    // Votes, then counts, per candidate: a sample goes to its nearest (the
    // first on a tie) and weighs its chroma, or one.
    public static long[] Tally(int[] points, int[] candidates, bool byChroma) {
        long[] result = new long[candidates.Length * 2];
        foreach (int p in points) {
            int best = 0; long bestD = long.MaxValue;
            for (int k = 0; k < candidates.Length; k++) {
                long d = D2(p, candidates[k]);
                if (d < bestD) { best = k; bestD = d; }
            }
            result[best] += byChroma ? Chroma(p) : 1;
            result[candidates.Length + best] += 1;
        }
        return result;
    }
}
'@
}

# ------------------------------------------------------------------ decoding

# 'png', 'jpg', or $null: by the first bytes, never by the name.
function Get-VivacPictureKind([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $head = New-Object byte[] 8
    $s = [IO.File]::OpenRead($Path)
    try { $n = $s.Read($head, 0, 8) } finally { $s.Dispose() }
    if ($n -ge 8 -and $head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47) { return 'png' }
    if ($n -ge 3 -and $head[0] -eq 0xFF -and $head[1] -eq 0xD8 -and $head[2] -eq 0xFF) { return 'jpg' }
    $null
}

# The samples of a picture as 0xRRGGBB integers. Windows' own decoder (WIC,
# through WPF), told to ignore colour profiles, as the Linux side ignores
# them; converted to 8-bit BGRA, not premultiplied.
function Read-VivacPictureSamples([string]$Path) {
    Add-Type -AssemblyName PresentationCore
    $stream = [IO.File]::OpenRead($Path)
    try {
        $options = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile -bor [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat
        $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($stream, $options, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]
        $bgra = New-Object Windows.Media.Imaging.FormatConvertedBitmap($frame, [Windows.Media.PixelFormats]::Bgra32, $null, 0)
        $w = $bgra.PixelWidth; $h = $bgra.PixelHeight
        $stride = $w * 4
        $pixels = New-Object byte[] ($stride * $h)
        $bgra.CopyPixels($pixels, $stride, 0)
    } finally { $stream.Dispose() }
    $nx = [Math]::Min($script:Grid, $w); $ny = [Math]::Min($script:Grid, $h)
    $out = New-Object System.Collections.Generic.List[int]
    for ($j = 0; $j -lt $ny; $j++) {
        $y = [int][Math]::Floor((2 * $j + 1) * $h / (2 * $ny))
        for ($i = 0; $i -lt $nx; $i++) {
            $x = [int][Math]::Floor((2 * $i + 1) * $w / (2 * $nx))
            $at = $y * $stride + $x * 4
            if ($pixels[$at + 3] -lt $script:Opaque) { continue }
            $out.Add(([int]$pixels[$at + 2] -shl 16) -bor ([int]$pixels[$at + 1] -shl 8) -bor [int]$pixels[$at])
        }
    }
    , $out.ToArray()
}

# ---------------------------------------------------- the corpus and measures

function Read-VivacTsvRows([string]$Path) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
        , @($line -split "`t")
    }
}

function Read-VivacCorpus {
    $data = Join-Path $script:Root 'data'
    $order = New-Object System.Collections.Generic.List[string]
    $role = @{}
    foreach ($f in Read-VivacTsvRows (Join-Path $data 'palette-corpus.tsv')) {
        # A colour listed twice keeps its first row.
        if (-not $role.ContainsKey($f[0])) { $order.Add($f[0]); $role[$f[0]] = $f[2] }
    }
    $index = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $index[$order[$i]] = $i }
    $root = @{}
    foreach ($f in Read-VivacTsvRows (Join-Path $data 'corpus-roots.tsv')) { $root[$f[0]] = $f[1] }
    $distance = @{}
    foreach ($f in Read-VivacTsvRows (Join-Path $data 'root-distance.tsv')) {
        $distance["$($f[0])+$($f[1])"] = [int]$f[2]
        $distance["$($f[1])+$($f[0])"] = [int]$f[2]
    }
    [pscustomobject]@{ Order = $order.ToArray(); Role = $role; Index = $index; Root = $root; Distance = $distance }
}

function Get-CorpusOf($Corpus, [string[]]$Roles) {
    @($Corpus.Order | Where-Object { $Roles -contains $Corpus.Role[$_] })
}

function Get-RootApart($Corpus, [string]$A, [string]$B) {
    if ($A -eq $B) { return 0 }
    $Corpus.Distance["$A+$B"]
}

function ConvertTo-Rgb([string]$Hex) { [Convert]::ToInt32($Hex, 16) }

function Get-Channel([double]$Component) {
    $Component = $Component / 255
    if ($Component -le 0.03928) { return $Component / 12.92 }
    [Math]::Pow(($Component + 0.055) / 1.055, 2.4)
}

# Remembered per colour: the walk asks for the same few dozen many times over.
$script:Luminance = @{}
function Get-Luminance([string]$Hex) {
    if ($script:Luminance.ContainsKey($Hex)) { return $script:Luminance[$Hex] }
    $v = ConvertTo-Rgb $Hex
    $l = 0.2126 * (Get-Channel (($v -shr 16) -band 255)) + 0.7152 * (Get-Channel (($v -shr 8) -band 255)) + 0.0722 * (Get-Channel ($v -band 255))
    $script:Luminance[$Hex] = $l
    $l
}

function Get-ContrastRatio([string]$A, [string]$B) {
    $first = Get-Luminance $A; $second = Get-Luminance $B
    ([Math]::Max($first, $second) + 0.05) / ([Math]::Min($first, $second) + 0.05)
}

function Get-D2([string]$A, [string]$B) { [VivacPicture]::D2((ConvertTo-Rgb $A), (ConvertTo-Rgb $B)) }

# Candidates by the votes of the samples nearest each, most first; ties by
# nearness to Near when given, then by corpus order (unique, so the order is
# total and Sort-Object's instability never shows).
function Get-Ranked([int[]]$Points, [string[]]$Candidates, $Corpus, [switch]$ByChroma, [string]$Near) {
    if (-not $Candidates -or -not $Candidates.Count) { return @() }
    $ints = [int[]]@($Candidates | ForEach-Object { ConvertTo-Rgb $_ })
    $tally = [VivacPicture]::Tally($Points, $ints, [bool]$ByChroma)
    $rows = for ($k = 0; $k -lt $Candidates.Count; $k++) {
        $tie = 0
        if ($Near) { $tie = Get-D2 $Candidates[$k] $Near }
        [pscustomobject]@{ Hex = $Candidates[$k]; Votes = $tally[$k]; Counts = $tally[$Candidates.Count + $k]; Tie = $tie; Index = $Corpus.Index[$Candidates[$k]] }
    }
    @($rows | Sort-Object @{ Expression = 'Votes'; Descending = $true }, @{ Expression = 'Counts'; Descending = $true },
        @{ Expression = 'Tie'; Descending = $false }, @{ Expression = 'Index'; Descending = $false } | ForEach-Object { $_.Hex })
}

function Get-NearestFirst([string[]]$Candidates, [string]$Anchor, $Corpus) {
    @($Candidates | ForEach-Object { [pscustomobject]@{ Hex = $_; D = (Get-D2 $_ $Anchor); Index = $Corpus.Index[$_] } } |
        Sort-Object D, Index | ForEach-Object { $_.Hex })
}

# The palette on ground Bg, or $null when some role has nothing that clears
# its floor.
function New-PaletteOnGround([int[]]$Points, [string]$Bg, $Corpus) {
    $p = [ordered]@{ COLOR_BG = $Bg }
    $lumBg = Get-Luminance $Bg
    $fgs = @(Get-CorpusOf $Corpus 'text' | Where-Object { (Get-ContrastRatio $_ $Bg) -ge $script:TextFloor })
    if (-not $fgs.Count) { return $null }
    $fg = @(Get-Ranked $Points $fgs $Corpus)[0]
    $p['COLOR_FG'] = $fg; $p['TERMINAL_FG'] = $fg
    $lumFg = Get-Luminance $fg

    $dim = @(Get-CorpusOf $Corpus 'text' | Where-Object { $_ -ne $fg -and (Get-Luminance $_) -lt $lumFg -and (Get-ContrastRatio $_ $Bg) -ge $script:DimFloor })
    if (-not $dim.Count) { return $null }
    $p['COLOR_FG_DIM'] = @(Get-NearestFirst $dim $fg $Corpus)[0]

    # The terminal's ground is a darker, neutral neighbour of the base, or the base itself.
    $deeper = @(Get-CorpusOf $Corpus 'deep' | Where-Object {
            $_ -ne $Bg -and (Get-Luminance $_) -le $lumBg -and [VivacPicture]::Chroma((ConvertTo-Rgb $_)) -le $script:Neutral -and
            (Get-ContrastRatio $fg $_) -ge $script:TextFloor })
    $p['TERMINAL_BG'] = $Bg
    if ($deeper.Count) { $p['TERMINAL_BG'] = @(Get-NearestFirst $deeper $Bg $Corpus)[0] }

    $surfaces = @(Get-CorpusOf $Corpus 'surface', 'raised', 'base' | Where-Object {
            $_ -ne $Bg -and (Get-Luminance $_) -gt $lumBg -and (Get-ContrastRatio $_ $Bg) -lt $script:SurfaceCeiling -and
            (Get-ContrastRatio $fg $_) -ge $script:DimFloor })
    if ($surfaces.Count -lt 3) { return $null }
    $ranked = @(Get-Ranked $Points $surfaces $Corpus -Near $Bg)
    $p['COLOR_SURFACE'] = $ranked[0]; $p['COLOR_SURFACE_ALT'] = $ranked[1]; $p['COLOR_BORDER_INACTIVE'] = $ranked[2]

    $ground = $Corpus.Root[$Bg]
    $accents = @(Get-CorpusOf $Corpus 'accent' | Where-Object {
            $Corpus.Root.ContainsKey($_) -and $Corpus.Root[$_] -ne $ground -and (Get-RootApart $Corpus $ground $Corpus.Root[$_]) -lt $script:Rupture -and
            (Get-ContrastRatio $_ $Bg) -ge $script:MarkFloor -and $_ -ne $fg -and $_ -ne $p['COLOR_FG_DIM'] })
    if (-not $accents.Count) { return $null }
    $accent = @(Get-Ranked $Points $accents $Corpus -ByChroma)[0]
    $p['COLOR_ACCENT'] = $accent

    $marks = @(Get-CorpusOf $Corpus 'accent', 'urgent' | Where-Object { $_ -ne $accent -and (Get-ContrastRatio $_ $Bg) -ge $script:MarkFloor })
    if (-not $marks.Count) { return $null }
    $p['COLOR_URGENT'] = @(Get-NearestFirst $marks $script:Anchors['COLOR_URGENT'] $Corpus)[0]
    $info = @($marks | Where-Object { $Corpus.Role[$_] -eq 'accent' -and $_ -ne $p['COLOR_URGENT'] -and (Get-D2 $_ $accent) -ge $script:Apart })
    if (-not $info.Count) { return $null }
    $p['COLOR_INFO'] = @(Get-NearestFirst $info $script:Anchors['COLOR_INFO'] $Corpus)[0]
    $ok = @($marks | Where-Object { $Corpus.Role[$_] -eq 'accent' -and $_ -ne $p['COLOR_URGENT'] -and $_ -ne $p['COLOR_INFO'] })
    if (-not $ok.Count) { return $null }
    $p['COLOR_OK'] = @(Get-NearestFirst $ok $script:Anchors['COLOR_OK'] $Corpus)[0]
    $muted = @(Get-CorpusOf $Corpus 'muted', 'accent' | Where-Object {
            $_ -ne $accent -and (Get-ContrastRatio $_ $Bg) -ge $script:MarkFloor -and (Get-D2 $_ $p['COLOR_FG_DIM']) -ge $script:Apart })
    if (-not $muted.Count) { return $null }
    $p['COLOR_MUTED'] = @(Get-NearestFirst $muted $script:Anchors['COLOR_MUTED'] $Corpus)[0]
    $p
}

# The palette for a set of samples: the most voted ground that carries one.
function New-VivacPaletteFromSamples([int[]]$Points) {
    $corpus = Read-VivacCorpus
    $grounds = @(Get-CorpusOf $corpus 'deep', 'base' | Where-Object { $corpus.Root.ContainsKey($_) })
    foreach ($bg in Get-Ranked $Points $grounds $corpus) {
        $made = New-PaletteOnGround $Points $bg $corpus
        if ($made) {
            $dominant = $corpus.Root[$made['COLOR_BG']]
            $accent = $corpus.Root[$made['COLOR_ACCENT']]
            return [pscustomobject]@{ Tokens = $made; Dominant = $dominant; Accent = $accent; Distance = (Get-RootApart $corpus $dominant $accent) }
        }
    }
    throw (T 'picture.no_palette')
}

# ------------------------------------------------------------------ the file

# NAME from --name, or from the picture's file name: lower-case letters,
# digits and dashes, starting with a letter, at most 32.
function Get-VivacPictureName([string]$Image, [string]$Wanted) {
    if ($Wanted) {
        if ($Wanted -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw (T 'picture.bad_name' @($Wanted)) }
        return $Wanted
    }
    $stem = ([IO.Path]::GetFileNameWithoutExtension($Image).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($stem -match '^[0-9]') { $stem = 'picture-' + $stem }
    if ($stem.Length -gt 32) { $stem = $stem.Substring(0, 32) }
    $stem = $stem.TrimEnd('-')
    if (-not $stem) { $stem = 'picture' }
    $stem
}

function Get-VivacPictureTitle([string]$Name) {
    (@($Name -split '-' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })) -join ' '
}

function Get-VivacVerdict([int]$Distance) {
    if ($Distance -le 2) { return 'affinity' }
    if ($Distance -le 4) { return 'tension' }
    'rupture'
}

# The palette file, byte for byte what the Linux half writes.
function ConvertTo-VivacPaletteText([string]$Name, [string]$Wallpaper, $Palette) {
    $title = Get-VivacPictureTitle $Name
    $lines = @(
        "# $title - a palette made from a picture (vivac theme from-image).",
        '# Every colour is the corpus colour the picture voted for that clears its floor.',
        "# @title: $title",
        '# @essence: Picture',
        "# @dominant: $($Palette.Dominant)",
        "# @accent: $($Palette.Accent)",
        "# @distance: $($Palette.Distance)",
        "# @verdict: $(Get-VivacVerdict $Palette.Distance)",
        "# @wallpaper: $Wallpaper")
    foreach ($key in Get-VivacTokenNames) { $lines += "$key=$($Palette.Tokens[$key])" }
    ($lines -join "`n") + "`n"
}

# Where a new palette goes: the shared root's themes/ when sharing is set up
# and the shared folder is there (so the other system sees it), otherwise
# this system's own.
function Get-VivacPaletteHome {
    $dirs = @(Get-VivacUserThemeDirs)
    $shared = Get-VivacSharedPath
    if ($shared -and (Test-Path -LiteralPath (Split-Path -Parent $shared) -PathType Container)) { return $dirs[0] }
    $dirs[$dirs.Count - 1]
}

function Write-VivacBytes([string]$Path, [byte[]]$Bytes) {
    $scratch = "$Path.vivac-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [IO.File]::WriteAllBytes($scratch, $Bytes)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [IO.File]::Move($scratch, $Path)
}

# Make the palette. Returns its name and file; with -DryRun writes nothing
# and returns the lines a terminal shows (swatches in truecolour).
function New-VivacPaletteFromPicture([string]$Image, [string]$Name, [switch]$DryRun, [string]$Directory) {
    $kind = $null
    if ($Image) { $kind = Get-VivacPictureKind $Image }
    if (-not $kind) { throw (T 'picture.unreadable' @($Image)) }
    try { $points = Read-VivacPictureSamples $Image } catch { throw (T 'picture.unreadable' @($Image)) }
    if (-not $points.Length) { throw (T 'picture.unreadable' @($Image)) }
    $Name = Get-VivacPictureName $Image $Name
    $shipped = @((Get-VivacDefaultTheme)) + @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'data\themes') -Filter '*.conf' | ForEach-Object { $_.BaseName })
    if ($shipped -contains $Name) { throw (T 'picture.taken' @($Name)) }
    $palette = New-VivacPaletteFromSamples $points

    if (-not $Directory) { $Directory = Get-VivacPaletteHome }
    $wallpaper = "$Name.$kind"
    $conf = Join-Path $Directory "$Name.conf"
    if ($DryRun) {
        $e = [char]27
        $floors = @{ COLOR_FG = 'COLOR_BG'; COLOR_FG_DIM = 'COLOR_BG'; COLOR_ACCENT = 'COLOR_BG'; TERMINAL_FG = 'TERMINAL_BG' }
        $out = @(Get-VivacPictureTitle $Name)
        foreach ($key in Get-VivacTokenNames) {
            $hex = $palette.Tokens[$key]
            $v = ConvertTo-Rgb $hex
            $note = ''
            if ($floors.ContainsKey($key)) { $note = '  {0}:1' -f ((Get-ContrastRatio $hex $palette.Tokens[$floors[$key]]).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) }
            $out += ('  {0}[48;2;{1};{2};{3}m      {0}[0m  {4,-22}{5}{6}' -f $e, (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255), $key, $hex, $note)
        }
        $out += T 'picture.roots' @($palette.Dominant, $palette.Accent, $palette.Distance, (Get-VivacVerdict $palette.Distance))
        $out += T 'picture.would_write' @($conf)
        return [pscustomobject]@{ Name = $Name; Path = $conf; Lines = $out; Text = (ConvertTo-VivacPaletteText $Name $wallpaper $palette) }
    }
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    # The picture first: a palette that names a wallpaper not there yet would
    # be worn for a moment with the fallback background.
    Write-VivacBytes (Join-Path $Directory $wallpaper) ([IO.File]::ReadAllBytes($Image))
    foreach ($other in 'png', 'jpg') {
        $stale = Join-Path $Directory "$Name.$other"
        if ($other -ne $kind -and (Test-Path -LiteralPath $stale)) { Remove-Item -LiteralPath $stale -Force }
    }
    $text = ConvertTo-VivacPaletteText $Name $wallpaper $palette
    Write-VivacFile -Path $conf -Text $text
    [pscustomobject]@{ Name = $Name; Path = $conf; Lines = @(T 'picture.wrote' @($Name, $conf)); Text = $text }
}

Export-ModuleMember -Function Get-VivacPictureKind, Read-VivacPictureSamples, New-VivacPaletteFromSamples,
    Get-VivacPictureName, ConvertTo-VivacPaletteText, Get-VivacPaletteHome, New-VivacPaletteFromPicture
