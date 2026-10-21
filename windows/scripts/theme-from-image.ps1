<#
.SYNOPSIS
  A new palette from a picture: vivac theme from-image IMAGE.

.DESCRIPTION
  Reads a PNG or JPEG and writes a palette beside the eight that ship, made
  only of corpus colours and held to the same floors (lib/Picture.psm1 says
  how). It goes to the shared root's themes\ folder when shared_settings
  points at one, so the other system can wear it too, and otherwise to
  %APPDATA%\vivac\themes. The picture is copied beside it and becomes its
  wallpaper. The palette then appears in the theme picker.

.PARAMETER Image
  The picture (PNG or JPEG).
.PARAMETER Name
  The palette's name (default: from the file name). Lower-case letters,
  digits and dashes; a shipped theme's name is refused.
.PARAMETER DryRun
  Print the palette as colour swatches; write nothing.
.PARAMETER Apply
  Wear it straight away (scripts\apply-theme.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Image,
    [string]$Name,
    [switch]$DryRun,
    [switch]$Apply
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Picture.psm1') -Force

# A relative path is the caller's, not .NET's working directory.
if ($Image -and -not [IO.Path]::IsPathRooted($Image)) { $Image = Join-Path (Get-Location).ProviderPath $Image }
try {
    $made = New-VivacPaletteFromPicture -Image $Image -Name $Name -DryRun:$DryRun
} catch {
    # From the menu nobody reads a console: say it on screen too.
    if ($Apply) { & (Join-Path $PSScriptRoot '..\bin\vivac.ps1') notify (T 'picture.failed_title') $_.Exception.Message }
    throw
}
foreach ($line in $made.Lines) { Write-Host $line }
if ($DryRun) { return }
if ($Apply) { & (Join-Path $PSScriptRoot 'apply-theme.ps1') -Theme $made.Name }
