# The boot menu and logo: the SYSTEM task takes nothing from the user's stage
# as it is, and what it writes is what GRUB and HackBGRT read.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Boot.psm1') -Force
Add-Type -AssemblyName System.Drawing

# boot-sync.ps1 runs as a whole only as SYSTEM, on the EFI partition; its
# functions are taken out of it and run against a scratch folder.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\boot-sync.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$keys = 'COLOR_BG', 'COLOR_FG', 'COLOR_FG_DIM', 'COLOR_SURFACE', 'COLOR_SURFACE_ALT', 'COLOR_ACCENT', 'COLOR_MUTED', 'COLOR_BORDER_INACTIVE'

function Write-Palette([string]$Dir, [hashtable]$Change) {
    $v = [ordered]@{ THEME = 'persephone'; WIDTH = '1920'; HEIGHT = '1080' }
    foreach ($k in $keys) { $v[$k] = '14201D' }
    foreach ($k in $Change.Keys) { $v[$k] = $Change[$k] }
    $lines = foreach ($k in $v.Keys) { if ($null -ne $v[$k]) { "$k=$($v[$k])" } }
    [IO.File]::WriteAllText((Join-Path $Dir 'palette.conf'), (($lines -join "`n") + "`n"))
}

$dir = New-TempProfile
try {
    $stage = $dir
    Case 'a well-formed palette is read' {
        Write-Palette $dir @{}
        $p = Read-Stage
        Assert-Equal '14201D' $p.COLOR_BG
        Assert-Equal 1920 $p.WIDTH
    }
    Case 'a colour that is not six hex digits is refused' {
        Write-Palette $dir @{ COLOR_ACCENT = '"; insmod evil' }
        Assert-Throws { Read-Stage } 'COLOR_ACCENT'
    }
    Case 'a missing colour is refused' {
        Write-Palette $dir @{ COLOR_FG = $null }
        Assert-Throws { Read-Stage } 'COLOR_FG'
    }
    Case 'an implausible screen size is refused' {
        Write-Palette $dir @{ WIDTH = '99999' }
        Assert-Throws { Read-Stage } 'WIDTH'
        Write-Palette $dir @{ HEIGHT = '100' }
        Assert-Throws { Read-Stage } 'size'
    }
    Case 'a theme name that is not a catalogue name is dropped, not written' {
        Write-Palette $dir @{ THEME = "x' }`n+ label {" }
        Assert-Equal '' (Read-Stage).THEME
    }
    Case 'a picture that is not a PNG is refused' {
        $b = New-Object System.Drawing.Bitmap(4, 4)
        $b.Save((Join-Path $dir 'splash.png'), [System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
        Assert-Throws { Read-Picture 'splash.png' 4 4 ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb) } 'PNG'
    }
    Case 'the boot logo is a 24-bit BMP with the 54-byte header HackBGRT reads' {
        $b = New-Object System.Drawing.Bitmap(8, 8)
        $b.Save((Join-Path $dir 'splash.png'), [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
        $pic = Read-Picture 'splash.png' 32 16 ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $pic.Save((Join-Path $dir 'splash.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp); $pic.Dispose()
        $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'splash.bmp'))
        Assert-Equal 54 ([BitConverter]::ToInt32($bytes, 10)) 'pixel offset'
        Assert-Equal 24 ([BitConverter]::ToInt16($bytes, 28)) 'bits per pixel'
        Assert-Equal 32 ([BitConverter]::ToInt32($bytes, 18)) 'drawn at the size asked'
    }
    Case 'a font is known by the name its file declares' {
        $be = { param([int]$n) [byte[]]@((($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)) }
        $ascii = [Text.Encoding]::ASCII
        $name = $ascii.GetBytes("DejaVu Sans Bold 14`0")
        $bytes = $ascii.GetBytes('FILE') + (& $be 4) + $ascii.GetBytes('PFF2') + $ascii.GetBytes('NAME') + (& $be $name.Length) + $name + $ascii.GetBytes('DATA') + (& $be 0)
        [IO.File]::WriteAllBytes((Join-Path $dir 'f.pf2'), $bytes)
        Assert-Equal 'DejaVu Sans Bold 14' (Get-FontName (Join-Path $dir 'f.pf2'))
    }
    Case 'the closest size is chosen, and bold falls back to regular' {
        $fonts = @{ 'DejaVu Sans Regular 10' = 1; 'DejaVu Sans Regular 16' = 1; 'DejaVu Sans Bold 14' = 1 }
        Assert-Equal 'DejaVu Sans Regular 16' (Select-Font $fonts 'Regular' 15)
        Assert-Equal 'DejaVu Sans Bold 14' (Select-Font $fonts 'Bold' 16)
        Assert-Equal 'DejaVu Sans Regular 10' (Select-Font @{ 'DejaVu Sans Regular 10' = 1 } 'Bold' 12)
    }
    Case 'the GRUB theme is written from the palette alone, frame pieces included' {
        Write-Palette $dir @{ COLOR_ACCENT = 'E1777D' }
        $p = Read-Stage
        $esp = Join-Path $dir 'esp'
        New-Item -ItemType Directory -Force -Path (Join-Path $esp 'grub\themes') | Out-Null
        $bg = New-Object System.Drawing.Bitmap(16, 9)
        [void](Write-GrubTheme $p "$esp\" $bg); $bg.Dispose()
        $theme = Join-Path $esp 'grub\themes\vivac'
        $text = [IO.File]::ReadAllText((Join-Path $theme 'theme.txt'))
        Assert-True ($text -match 'desktop-image: "background.png"')
        Assert-True ($text -match '"#E1777D"') 'the accent'
        foreach ($k in 'nw', 'n', 'ne', 'w', 'c', 'e', 'sw', 's', 'se') {
            Assert-True (Test-Path -LiteralPath (Join-Path $theme "menu_$k.png")) "menu_$k.png"
            Assert-True (Test-Path -LiteralPath (Join-Path $theme "select_$k.png")) "select_$k.png"
        }
    }
    Case 'the boot logo is the whole screen in the base colour, with the mark' {
        $t = Read-VivacTheme 'persephone'
        $svg = Get-VivacSplashSvg $t 1920 1080
        Assert-True ($svg -match '<rect width="1920" height="1080" fill="#14201D"/>') 'base colour'
        Assert-True ($svg -match 'clip-path="url\(#coin\)"') 'the mark'
        Assert-True ($svg -notmatch '@[A-Z_]+(:[a-z]+)?@') 'every token expanded'
    }
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
