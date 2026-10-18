<#
.SYNOPSIS
  The first-run wizard: three questions and a tour that waits for you.

.DESCRIPTION
  A terminal wizard on purpose: a desktop driven from the keyboard should not
  open by handing you a mouse. The language comes first, because it changes
  every question after it; then the modifier key, then the theme, applied
  where you can see it. Then the tour, which does not list the keys: it asks
  for one and notices when you press it, by asking GlazeWM what changed.

  Every string comes from i18n/; nothing the wizard says is written here.

.PARAMETER FirstRun
  Do nothing if the wizard has already been completed once.
#>
param([switch]$FirstRun)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Apps.psm1') -Force

$marker = Join-Path (Get-VivacPaths).State 'welcome-done'
if ($FirstRun -and (Test-Path -LiteralPath $marker)) { return }

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$settings = Read-VivacSettings
[void](Import-VivacStrings $settings['language'])

function Say([string]$Key, [object[]]$Arguments) { Write-Host (T $Key $Arguments) }
function Title([string]$Key) { Write-Host ''; Write-Host ('  ' + (T $Key)) -ForegroundColor Cyan; Write-Host '' }

# A numbered choice. Returns the index, or the default on Enter.
function Ask-Choice([string[]]$Options, [int]$Default) {
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = ' '
        if ($i -eq $Default) { $mark = '*' }
        Write-Host ("   {0} {1}) {2}" -f $mark, ($i + 1), $Options[$i])
    }
    while ($true) {
        $answer = Read-Host ('  ' + (T 'welcome.choose' @(1, $Options.Count)))
        if (-not $answer) { return $Default }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n - 1 }
    }
}

function Bind([string]$Bind) { Format-VivacBind $Bind (Read-VivacSettings)['mod'] }

# Wait until $Test returns true, polling. Esc skips the step; the skip is
# said, not hidden.
function Wait-For([scriptblock]$Test, [int]$TimeoutSeconds = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Test) { Say 'welcome.done_step'; return $true }
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Escape') { Say 'welcome.skipped'; return $false }
        }
        Start-Sleep -Milliseconds 400
    }
    Say 'welcome.skipped'
    $false
}

function Get-Windows {
    $w = Get-GlazeWMState 'windows'
    if ($w -and $w.PSObject.Properties['windows']) { return @($w.windows) }
    @()
}
function Get-FocusedWorkspace {
    $ws = Get-GlazeWMState 'workspaces'
    if (-not $ws) { return $null }
    (@($ws.workspaces) | Where-Object { $_.hasFocus } | Select-Object -First 1).name
}
function Test-Surface([string]$Name) {
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting("Local\vivac-$Name", [ref]$m)) { $m.Dispose(); return $true }
    $false
}

Clear-Host
Write-Host ''
Write-Host '   v i v a c' -ForegroundColor Magenta
Say 'welcome.intro'

# ----------------------------------------------------------------- language
Title 'welcome.language_title'
$langs = @('es', 'en')
$i = Ask-Choice @('Espanol', 'English') ([Math]::Max(0, [array]::IndexOf($langs, $settings['language'])))
Set-VivacSetting language $langs[$i]
[void](Import-VivacStrings $langs[$i])
Say 'welcome.language_note'

# ----------------------------------------------------------------- modifier
Title 'welcome.mod_title'
Say 'welcome.mod_explain'
$mods = @('alt', 'lwin')
$i = Ask-Choice @((T 'welcome.mod_alt'), (T 'welcome.mod_win')) ([Math]::Max(0, [array]::IndexOf($mods, $settings['mod'])))
Set-VivacSetting mod $mods[$i]

# -------------------------------------------------------------------- theme
Title 'welcome.theme_title'
Say 'welcome.theme_explain'
$names = @(Get-VivacCatalogue)
$labels = @($names | ForEach-Object { $t = Read-VivacTheme $_; "$($t.Title) - $($t.Essence)" })
while ($true) {
    $i = Ask-Choice $labels ([Math]::Max(0, [array]::IndexOf($names, (Read-VivacSettings)['theme'])))
    Say 'welcome.theme_applying' @($labels[$i])
    & (Join-Path $root 'scripts\apply-theme.ps1') -Theme $names[$i] | Out-Null
    $keep = Read-Host ('  ' + (T 'welcome.theme_keep'))
    if (-not $keep -or $keep -match '^[sSyY]') { break }
}

# --------------------------------------------------------------------- tour
if (-not (Test-VivacAppRunning 'glazewm')) {
    Say 'welcome.no_glazewm'
} else {
    Title 'welcome.tour_title'
    Say 'welcome.tour_explain'

    Say 'welcome.step_open' @(Bind 'MOD+enter')
    $before = @(Get-Windows | Where-Object { $_.processName -eq 'WindowsTerminal' }).Count
    [void](Wait-For { @(Get-Windows | Where-Object { $_.processName -eq 'WindowsTerminal' }).Count -gt $before })

    Say 'welcome.step_close' @(Bind 'MOD+q')
    $before = @(Get-Windows).Count
    [void](Wait-For { @(Get-Windows).Count -lt $before })

    Say 'welcome.step_workspace' @(Bind 'MOD+2')
    [void](Wait-For { (Get-FocusedWorkspace) -eq '2' })

    Say 'welcome.step_back' @(Bind 'MOD+1')
    [void](Wait-For { (Get-FocusedWorkspace) -eq '1' })

    Say 'welcome.step_carry' @((Bind 'MOD+enter'), (Bind 'MOD+shift+3'))
    [void](Wait-For { $ws = Get-GlazeWMState 'workspaces'; $ws -and @(@($ws.workspaces) | Where-Object { $_.name -eq '3' -and @($_.children).Count -gt 0 }).Count -gt 0 })

    Say 'welcome.step_walk' @((Bind 'MOD+oem_comma'), (Bind 'MOD+oem_period'))
    $start = Get-FocusedWorkspace
    [void](Wait-For { $now = Get-FocusedWorkspace; $now -and $now -ne $start })

    Say 'welcome.step_help' @(Bind 'MOD+f1')
    [void](Wait-For { Test-Surface 'help' })
    Say 'welcome.step_help_more'

    Say 'welcome.step_theme' @(Bind 'MOD+shift+t')
    [void](Wait-For { Test-Surface 'theme' })

    Say 'welcome.step_bar'
    Read-Host ('  ' + (T 'welcome.press_enter')) | Out-Null

    # Installing is easy to try; undoing it is the part that teaches the
    # package manager. Both are asked for, and both are watched.
    $pkg = 'sharkdp.bat'
    Say 'welcome.step_install' @("winget install --id $pkg -e")
    [void](Wait-For { (winget list --id $pkg -e 2>$null | Out-String) -match [regex]::Escape($pkg) } 600)
    Say 'welcome.step_uninstall' @("winget uninstall --id $pkg -e")
    [void](Wait-For { (winget list --id $pkg -e 2>$null | Out-String) -notmatch [regex]::Escape($pkg) } 600)
}

Write-VivacFile -Path $marker -Text ((Get-Date).ToString('s') + "`n")
Title 'welcome.end_title'
Say 'welcome.end' @(Bind 'MOD+f1')
Read-Host ('  ' + (T 'welcome.press_enter')) | Out-Null
