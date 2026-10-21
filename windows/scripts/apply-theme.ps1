<#
.SYNOPSIS
  Switch the whole desktop to a palette from the catalogue, live.

.DESCRIPTION
  Writes the theme into the settings file, then deploys again: every themed
  surface is rendered from the new palette and every running program is told
  to re-read its configuration. What changes in front of you: the wallpaper,
  the accent colour, the window borders, the bar, the launcher, and the
  terminals already open (Windows Terminal reloads its settings by itself).
  Neovim keeps its colours until it is restarted -- there is no signal to
  send it -- but its compiled theme cache is rebuilt here, so the next editor
  opens in the new palette instead of the old one.

.PARAMETER Theme
  The theme to switch to (default: re-apply whatever is set).
.PARAMETER List
  Print the catalogue and exit.
.PARAMETER DryRun
  Show what would change; writes nothing, not even the setting.
.PARAMETER NoReload
  Render only.
#>
[CmdletBinding()]
param(
    [string]$Theme,
    [switch]$List,
    [switch]$DryRun,
    [switch]$NoReload
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Apps.psm1') -Force

if ($List) {
    $current = (Read-VivacSettings)['theme']
    foreach ($name in Get-VivacCatalogue) {
        $t = Read-VivacTheme $name
        $mark = ' '
        if ($name -eq $current) { $mark = '*' }
        '{0} {1,-16} {2} - {3}' -f $mark, $name, $t.Title, $t.Essence
    }
    return
}

if ($Theme) {
    if ((Get-VivacCatalogue) -notcontains $Theme) {
        throw (T 'theme.unknown' @($Theme, ((Get-VivacCatalogue) -join ', ')))
    }
    if (-not $DryRun) { Set-VivacSetting -Key theme -Value $Theme }
}

# A dry run must not write the setting, so it hands the theme to deploy.ps1
# directly instead.
$deployArgs = @{ DryRun = $DryRun; NoReload = $NoReload }
if ($DryRun -and $Theme) { $deployArgs['Theme'] = $Theme }
& (Join-Path $PSScriptRoot 'deploy.ps1') @deployArgs

if ($DryRun -or $NoReload) { return }

# base46 compiles its highlights once and caches the result under a name that
# does not change with the palette, so nothing in that cache looks stale. It
# is dropped and rebuilt headless now; rebuilt rather than left for the next
# launch, because init.lua reads the cache unconditionally and an editor
# started without it opens on an error.
$nvim = Find-VivacApp 'nvim'
$data = Join-Path (Get-VivacPaths).LocalAppData 'nvim-data'
if ($nvim -and (Test-Path -LiteralPath (Join-Path $data 'lazy\base46'))) {
    Remove-Item -LiteralPath (Join-Path $data 'base46') -Recurse -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $nvim -ArgumentList @('--headless', '-c', '"lua require(''base46'').load_all_highlights()"', '-c', 'qa!') -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}

$t = Read-VivacTheme (Read-VivacSettings)['theme']
& (Join-Path $PSScriptRoot '..\bin\vivac.ps1') notify (T 'theme.applied_title') (T 'theme.applied' @($t.Title, $t.Essence))
