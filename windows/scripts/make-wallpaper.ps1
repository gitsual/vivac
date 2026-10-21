<#
.SYNOPSIS
  Render wallpapers (and the banner) from the theme files.

.DESCRIPTION
  Each wallpaper is templates/wallpaper/base.svg.in in the theme's colours,
  with an ornament on top only when the theme has earned one (see
  Get-VivacOrnament in lib/Desktop.psm1). SVG first, then a 3840x2160 PNG
  through the Edge that ships with Windows. The artwork is a build artifact,
  like everything else here: nothing is painted by hand.

.PARAMETER Theme
  One theme (default: the one in the settings file).
.PARAMETER All
  Every theme in the catalogue.
.PARAMETER Logo
  Also render the banner and the mark from templates/brand/.
.PARAMETER OutDir
  Where to write (default: dist\wallpapers under the checkout).
.PARAMETER NoRaster
  SVG only.
#>
[CmdletBinding()]
param(
    [string]$Theme,
    [switch]$All,
    [switch]$Logo,
    [string]$OutDir,
    [switch]$NoRaster
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Desktop.psm1') -Force
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist\wallpapers' }

$names = @()
if ($All) { $names = @(Get-VivacCatalogue) }
elseif ($Theme) { $names = @($Theme) }
else { $names = @((Read-VivacSettings)['theme']) }

foreach ($name in $names) {
    $t = Read-VivacTheme $name
    $svg = Join-Path $OutDir "$name.svg"
    Write-VivacFile -Path $svg -Text (Get-VivacWallpaperSvg $t)
    $line = "$name  $svg"
    if (-not $NoRaster) {
        $png = Join-Path $OutDir "$name.png"
        ConvertTo-VivacPng -SvgPath $svg -PngPath $png
        $line += "  $png"
    }
    $line
}

if ($Logo) {
    $t = Read-VivacTheme $names[0]
    $tokens = Get-VivacTokens -Theme $t
    foreach ($kind in 'logo', 'logo-mark') {
        $svg = Join-Path $OutDir "$kind.svg"
        Write-VivacFile -Path $svg -Text (Expand-VivacTemplate -Text (Read-VivacText (Join-Path $root "templates\brand\$kind.svg.in")) -Tokens $tokens -Facts $null)
        $svg
    }
}
