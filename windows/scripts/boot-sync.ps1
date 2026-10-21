<#
.SYNOPSIS
  Carry the theme onto the EFI system partition: HackBGRT's boot logo and
  GRUB's theme. Runs as SYSTEM, from task \vivac\boot-sync.

.DESCRIPTION
  Installed by scripts\apply-system.ps1 -Boot into %ProgramFiles%\vivac,
  where only administrators can change it; never run from the checkout.

  Reads %ProgramData%\vivac\boot-stage (written by the user, lib\Boot.psm1)
  and trusts none of it: the palette is a fixed list of keys whose values
  must be six hex digits, the size must be a plausible screen, and each
  picture is decoded and encoded anew, so what reaches the partition is a
  file this script wrote. The GRUB theme (theme.txt and its frame pieces) is
  written here from the palette alone.

  Writes only \EFI\HackBGRT\splash.bmp and \grub\themes\vivac\ on the
  partition, and logs to %ProgramFiles%\vivac\boot-sync.log.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$stage = Join-Path $env:ProgramData 'vivac\boot-stage'
# Not under %ProgramData%\vivac: the user may write there, and a log SYSTEM
# appends to must not be a file the user can swap for a link.
$log = Join-Path $env:ProgramFiles 'vivac\boot-sync.log'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format s), $m) -Encoding ASCII }

# ---------------------------------------------------------------- the stage

$keys = 'COLOR_BG', 'COLOR_FG', 'COLOR_FG_DIM', 'COLOR_SURFACE', 'COLOR_SURFACE_ALT', 'COLOR_ACCENT', 'COLOR_MUTED', 'COLOR_BORDER_INACTIVE'
function Read-Stage {
    $path = Join-Path $stage 'palette.conf'
    if ((Get-Item -LiteralPath $path).Length -gt 4096) { throw 'palette.conf is too large' }
    $kv = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() }
    }
    $p = @{}
    foreach ($k in $keys) {
        if (-not $kv.ContainsKey($k) -or $kv[$k] -notmatch '^[0-9A-Fa-f]{6}$') { throw "palette.conf: $k is missing or not a colour" }
        $p[$k] = $kv[$k].ToUpperInvariant()
    }
    foreach ($k in 'WIDTH', 'HEIGHT') {
        if (-not $kv.ContainsKey($k) -or $kv[$k] -notmatch '^\d{3,4}$') { throw "palette.conf: $k is not a size" }
        $p[$k] = [int]$kv[$k]
    }
    if ($p.WIDTH -lt 640 -or $p.WIDTH -gt 7680 -or $p.HEIGHT -lt 480 -or $p.HEIGHT -gt 4320) { throw 'palette.conf: implausible screen size' }
    $p.THEME = ''
    if ($kv.ContainsKey('THEME') -and $kv['THEME'] -match '^[a-z0-9-]{1,40}$') { $p.THEME = $kv['THEME'] }
    $p
}

# Decoded and drawn onto a fresh bitmap of exactly the screen's size.
function Read-Picture([string]$Name, [int]$W, [int]$H, $Format) {
    $path = Join-Path $stage $Name
    if ((Get-Item -LiteralPath $path).Length -gt 40MB) { throw "$Name is too large" }
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(, $bytes)
    $src = [System.Drawing.Image]::FromStream($ms, $false, $true)
    try {
        if ($src.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) { throw "$Name is not a PNG" }
        $dst = New-Object System.Drawing.Bitmap($W, $H, $Format)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($src, 0, 0, $W, $H)
        $g.Dispose()
        $dst
    } finally { $src.Dispose(); $ms.Dispose() }
}

function ConvertTo-Color([string]$Hex, [int]$Alpha = 255) {
    [System.Drawing.Color]::FromArgb($Alpha, [Convert]::ToInt32($Hex.Substring(0, 2), 16), [Convert]::ToInt32($Hex.Substring(2, 2), 16), [Convert]::ToInt32($Hex.Substring(4, 2), 16))
}

# --------------------------------------------------------- the GRUB theme

# A rounded frame cut into GRUB's nine pieces (<prefix>nw.png ... se.png):
# corners of the radius, edges and centre two pixels wide, stretched by GRUB.
function Write-Frame([string]$Dir, [string]$Prefix, $Fill, $Border, [int]$Stroke, [int]$Radius) {
    $r = $Radius; $s = 2 * $r + 2
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $inset = $Stroke / 2.0
    $d = 2 * ($r - $inset)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x0 = $inset; $x1 = $s - $inset - $d
    $path.AddArc($x0, $x0, $d, $d, 180, 90); $path.AddArc($x1, $x0, $d, $d, 270, 90)
    $path.AddArc($x1, $x1, $d, $d, 0, 90); $path.AddArc($x0, $x1, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.SolidBrush($Fill)
    $g.FillPath($brush, $path)
    if ($Stroke -gt 0) { $pen = New-Object System.Drawing.Pen($Border, $Stroke); $g.DrawPath($pen, $path); $pen.Dispose() }
    $brush.Dispose(); $g.Dispose()
    $cuts = @{
        nw = @(0, 0, $r, $r); n = @($r, 0, 2, $r); ne = @(($r + 2), 0, $r, $r)
        w = @(0, $r, $r, 2); c = @($r, $r, 2, 2); e = @(($r + 2), $r, $r, 2)
        sw = @(0, ($r + 2), $r, $r); s = @($r, ($r + 2), 2, $r); se = @(($r + 2), ($r + 2), $r, $r)
    }
    foreach ($k in $cuts.Keys) {
        $c = $cuts[$k]
        $piece = $bmp.Clone((New-Object System.Drawing.Rectangle($c[0], $c[1], $c[2], $c[3])), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $piece.Save((Join-Path $Dir "$Prefix$k.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $piece.Dispose()
    }
    $bmp.Dispose()
}

# The name a PFF2 font file declares (its NAME section), which is what a
# GRUB theme refers to it by.
function Get-FontName([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $i = 0
    while ($i + 8 -le $b.Length) {
        $tag = [Text.Encoding]::ASCII.GetString($b, $i, 4)
        $len = ($b[$i + 4] -shl 24) -bor ($b[$i + 5] -shl 16) -bor ($b[$i + 6] -shl 8) -bor $b[$i + 7]
        if ($tag -eq 'NAME') { return [Text.Encoding]::ASCII.GetString($b, $i + 8, $len).TrimEnd([char]0) }
        if ($tag -eq 'DATA' -or $len -lt 0) { break }
        $i += 8 + $len
    }
    $null
}

# GRUB ships DejaVu with its starfield theme; vivac's monospace has no PFF2
# build on Windows (grub-mkfont is Linux's), so the theme takes those.
function Copy-Fonts([string]$Esp, [string]$Dir) {
    $fonts = @{}
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Esp 'grub\themes') -Recurse -Filter '*.pf2' -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -ne $Dir })
    foreach ($f in $sources) {
        $name = Get-FontName $f.FullName
        if (-not $name -or $fonts.ContainsKey($name)) { continue }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dir $f.Name) -Force
        $fonts[$name] = $f.Name
    }
    $fonts
}

function Select-Font($Fonts, [string]$Style, [int]$Size) {
    $best = $null; $gap = 999
    foreach ($n in $Fonts.Keys) {
        if ($n -notmatch "^(.*) $Style (\d+)$") { continue }
        $d = [Math]::Abs([int]$Matches[2] - $Size)
        if ($d -lt $gap) { $best = $n; $gap = $d }
    }
    if (-not $best -and $Style -ne 'Regular') { return Select-Font $Fonts 'Regular' $Size }
    $best
}

function Write-GrubTheme($P, [string]$Esp, $Background) {
    $dir = Join-Path $Esp 'grub\themes\vivac'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force
    $Background.Save((Join-Path $dir 'background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    # ReGreet's frame (system/etc/greetd/regreet.css in the source): the
    # surface at 92%, a two-pixel inactive border, twelve-pixel corners;
    # the selected entry is the accent, as its suggested-action button.
    Write-Frame $dir 'menu_' (ConvertTo-Color $P.COLOR_SURFACE 235) (ConvertTo-Color $P.COLOR_BORDER_INACTIVE) 2 12
    Write-Frame $dir 'select_' (ConvertTo-Color $P.COLOR_ACCENT) (ConvertTo-Color $P.COLOR_ACCENT) 0 8
    $fonts = Copy-Fonts $Esp $dir
    $item = Select-Font $fonts 'Regular' 16
    $small = Select-Font $fonts 'Regular' 12
    $title = Select-Font $fonts 'Bold' 16
    $fontLine = { param($n) if ($n) { "font = `"$n`"" } else { '' } }
    $itemFont = ''; $selFont = ''
    if ($item) { $itemFont = "item_font = `"$item`""; $selFont = "selected_item_font = `"$item`"" }
    $termFont = ''
    if ($item) { $termFont = "terminal-font: `"$item`"" }
    $text = @"
# vivac: written by boot-sync.ps1 from the theme '$($P.THEME)'. Rewritten on
# every theme switch on Windows; changes made here do not last.
title-text: ""
desktop-image: "background.png"
desktop-color: "#$($P.COLOR_BG)"
$termFont
terminal-box: "menu_*.png"

+ label {
  left = 0 top = 21% width = 100% height = 32
  align = "center" text = "vivac" color = "#$($P.COLOR_ACCENT)"
  $(& $fontLine $title)
}
+ boot_menu {
  left = 31% top = 28% width = 38% height = 44%
  $itemFont
  $selFont
  item_color = "#$($P.COLOR_FG)"
  selected_item_color = "#$($P.COLOR_BG)"
  item_height = 34 item_padding = 14 item_spacing = 6
  icon_width = 0 icon_height = 0 item_icon_space = 0
  menu_pixmap_style = "menu_*.png"
  selected_item_pixmap_style = "select_*.png"
  scrollbar = false
}
+ progress_bar {
  id = "__timeout__"
  left = 31% top = 76% width = 38% height = 4
  show_text = false
  fg_color = "#$($P.COLOR_ACCENT)" bg_color = "#$($P.COLOR_SURFACE)" border_color = "#$($P.COLOR_SURFACE)"
}
+ label {
  id = "__timeout__"
  left = 0 top = 79% width = 100% height = 24
  align = "center" color = "#$($P.COLOR_FG_DIM)"
  text = "@TIMEOUT_NOTIFICATION_MIDDLE@"
  $(& $fontLine $small)
}
+ label {
  left = 0 top = 93% width = 100% height = 24
  align = "center" color = "#$($P.COLOR_MUTED)"
  text = "Enter: boot   -   e: edit   -   c: console"
  $(& $fontLine $small)
}
"@
    [IO.File]::WriteAllText((Join-Path $dir 'theme.txt'), (($text -split "`r?`n") -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    $fonts.Count
}

# Each free-looking letter is tried, and a mount counts only if Windows' boot
# loader is on it (the same as Mount-VivacEsp in lib\Boot.psm1).
function Mount-Esp {
    foreach ($l in [char[]](89..71)) {
        if (Test-Path "$($l):\") { continue }
        mountvol "$($l):" /s 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        if (Test-Path -LiteralPath "$($l):\EFI\Microsoft\Boot\bootmgfw.efi") { return "$($l):\" }
        mountvol "$($l):" /d 2>&1 | Out-Null
    }
    $null
}

# --------------------------------------------------------------------- run

$esp = $null
try {
    $p = Read-Stage
    $splash = Read-Picture 'splash.png' $p.WIDTH $p.HEIGHT ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $background = Read-Picture 'background.png' $p.WIDTH $p.HEIGHT ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

    $esp = Mount-Esp
    if (-not $esp) { throw 'the EFI system partition could not be mounted' }
    $hb = Join-Path $esp 'EFI\HackBGRT'
    if (Test-Path -LiteralPath $hb) {
        # 24-bit with the 54-byte header HackBGRT reads: what GDI+ writes
        # for Format24bppRgb.
        $splash.Save((Join-Path $hb 'splash.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)
    } else { Log 'no \EFI\HackBGRT on the partition: boot logo left alone' }
    if (Test-Path -LiteralPath (Join-Path $esp 'grub')) {
        $n = Write-GrubTheme $p $esp $background
        Log "grub theme written ($n fonts)"
    } else { Log 'no \grub on the partition: GRUB theme left alone' }
    Log "synced theme '$($p.THEME)' at $($p.WIDTH)x$($p.HEIGHT)"
} catch {
    Log "failed: $($_.Exception.Message)"
    exit 1
} finally {
    if ($esp) { mountvol $esp.TrimEnd('\') /d 2>&1 | Out-Null }
}
