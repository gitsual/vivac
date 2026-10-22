<#
.SYNOPSIS
  Render and place every vivac configuration for this machine.

.DESCRIPTION
  Renders the themed templates with the palette named in the settings file,
  the per-machine templates with the settings and hardware facts too, copies
  the static files, merges the terminal and launcher settings, and dresses
  the Windows desktop (wallpaper, accent, dark mode). Then it tells whatever
  is running to re-read its configuration.

  Nothing is deleted: a file that is not exactly what vivac wrote last time
  is copied to %LOCALAPPDATA%\vivac\backups\<timestamp>\ before it is
  replaced, and scripts/uninstall.ps1 undoes a deploy.

.PARAMETER DryRun
  Print what would be written, backed up or removed, and touch nothing.
.PARAMETER Package
  Deploy only these: glazewm zebar flow terminal nvim desktop (default: all).
.PARAMETER NoReload
  Write files only; do not restart or signal running programs.
.PARAMETER Theme
  Render with this palette instead of the one in the settings file, without
  writing the setting (scripts/apply-theme.ps1 -DryRun previews through it).
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string[]]$Package,
    [switch]$NoReload,
    [string]$Theme
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Deploy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Desktop.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Apps.psm1') -Force

$paths = Get-VivacPaths
# Rendered commands point back into the checkout, and GlazeWM's shell-exec
# splits its command line on spaces: a checkout path with a space in it would
# deploy bindings that silently do nothing.
if ($paths.Repo -match '\s') {
    throw (T 'deploy.repo_has_space' @($paths.Repo))
}

$all = @(Get-VivacPackages) + 'desktop'
if (-not $Package) { $Package = $all }
$Package = @($Package | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($p in $Package) {
    if ($all -notcontains $p) { throw (T 'deploy.unknown_package' @($p, ($all -join ' '))) }
}
$filePackages = @($Package | Where-Object { $_ -ne 'desktop' })

$settings = Read-VivacSettings
[void](Import-VivacStrings $settings['language'])
if ($Theme) { $settings['theme'] = $Theme }
$palette = Read-VivacTheme $settings['theme']

# Facts first: the per-machine renders cannot be made without them. A dry run
# detects in memory rather than writing the facts file.
$facts = Read-VivacFacts
if (-not $facts) {
    $detector = Join-Path $PSScriptRoot 'hardware-facts.ps1'
    if ($DryRun) {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vivac-facts-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        & $detector | Set-Content -LiteralPath $scratch -Encoding ASCII
        $facts = Read-VivacFacts @($scratch)
        Remove-Item -LiteralPath $scratch -Force
    } else {
        & $detector -Emit
        $facts = Read-VivacFacts
    }
}

$mode = ''
if ($DryRun) { $mode = ' ' + (T 'deploy.dry_run') }
Write-Host (T 'deploy.header' @($palette.Title, $settings['mod'], $mode))

$plan = @()
if ($filePackages.Count) { $plan = @(Get-VivacPlan -Theme $palette -Settings $settings -Facts $facts -Packages $filePackages) }

# The bar is the only way back to a minimized window: a pack that would load
# blank is never written. It is assembled as it would land (what is there
# now, overlaid with the plan) and checked by lib/Bar.psm1; on a problem the
# bar keeps what it has and the rest of the deploy goes on.
$barGuard = $false
if ($filePackages -contains 'zebar') {
    Import-Module (Join-Path $PSScriptRoot '..\lib\Bar.psm1') -Force
    $barPack = (Get-VivacBarPaths).Pack
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('vivac-bar-stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $stage)
    try {
        if (Test-Path -LiteralPath $barPack) { Copy-Item -Path (Join-Path $barPack '*') -Destination $stage -Recurse -Force }
        foreach ($item in $plan | Where-Object { $_.Target.StartsWith($barPack + '\', [StringComparison]::OrdinalIgnoreCase) }) {
            $dest = Join-Path $stage $item.Target.Substring($barPack.Length + 1)
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest))
            [IO.File]::WriteAllText($dest, $item.Text, (New-Object Text.UTF8Encoding $false))
        }
        $barProblems = @(Test-VivacBarFiles $stage)
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($barProblems.Count) {
        foreach ($p in $barProblems) { Write-Warning (T 'deploy.bar_refused' @($p)) }
        $plan = @($plan | Where-Object { $_.Package -ne 'zebar' })
        $filePackages = @($filePackages | Where-Object { $_ -ne 'zebar' })
    } elseif (-not $DryRun) {
        # The pack on disk now is the one to fall back on, if it is the one
        # seen drawn (Test-VivacBarProven).
        if (Test-VivacBarProven) { [void](Save-VivacBarLastGood) }
        $barGuard = $true
    }
}

# Flow Launcher saves its own settings when it exits, so a file written under
# a running launcher would be overwritten on its way out. It is stopped first
# and started again afterwards.
$flowWasRunning = $false
$flowSettings = Get-FlowSettingsPath
if (-not $DryRun -and ($plan | Where-Object { $_.Target -eq $flowSettings })) {
    $flowWasRunning = Stop-VivacApp 'flow'
}

$results = @()
if ($plan.Count -or $filePackages.Count) { $results = @(Invoke-VivacPlan -Plan $plan -Packages $filePackages -DryRun:$DryRun) }
foreach ($r in $results) {
    $line = '  {0,-15} {1,-9} {2}' -f "[$($r.Action)]", $r.Package, $r.Target
    if ($r.Action -eq 'unchanged') { Write-Verbose $line } else { Write-Host $line }
}

if ($Package -contains 'desktop') {
    foreach ($line in Set-VivacDesktop -Theme $palette -DryRun:$DryRun) { Write-Host "  [desktop]      $line" }
}

$changed = @($results | Where-Object { $_.Action -notin 'unchanged', 'kept-edited' })
$backups = @($results | Where-Object { $_.Action -eq 'backup+update' })
$edited = @($results | Where-Object { $_.Action -eq 'kept-edited' })
$summaryKey = 'deploy.summary'
if ($DryRun) { $summaryKey = 'deploy.summary_dry' }
Write-Host (T $summaryKey @($changed.Count, @($results | Where-Object { $_.Action -eq 'unchanged' }).Count, $backups.Count))
if ($backups.Count -and -not $DryRun) { Write-Host (T 'deploy.backups_at' @($paths.Backups)) }
foreach ($e in $edited) { Write-Warning (T 'deploy.kept_edited' @($e.Target)) }

if ($DryRun -or $NoReload) {
    if ($flowWasRunning) { Start-VivacApp 'flow' }
    return
}

# Reloads. Each one is bounded: a program that does not answer must not hold
# up the rest, or the theme picker that calls this.
$touched = @($changed | ForEach-Object { $_.Package } | Sort-Object -Unique)
if ($touched -contains 'glazewm') { Invoke-GlazeWM 'command', 'wm-reload-config' | Out-Null }
if ($Package -contains 'glazewm') { [void](Restart-VivacDaemon) }
if ($touched -contains 'zebar' -and (Test-VivacAppRunning 'zebar')) {
    $restartedAt = Get-Date
    [void](Restart-VivacBar)
    # A pack that passed the checks can still fail to draw; then the last one
    # seen drawn goes back.
    if ($barGuard -and -not (Wait-VivacBarAlive $restartedAt)) {
        if (Restore-VivacBarLastGood) { Write-Warning (T 'deploy.bar_rolled_back') } else { Write-Warning (T 'deploy.bar_not_drawn') }
    }
}
if ($flowWasRunning) { Start-VivacApp 'flow' }
