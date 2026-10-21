<#
.SYNOPSIS
  Install the packages and deploy the configuration: the whole desktop.

.DESCRIPTION
  1. installs the base winget packages, and any optional set asked for
  2. detects the hardware facts
  3. deploys every configuration (scripts/deploy.ps1)
  4. starts GlazeWM, which starts the bar, and opens the first-run wizard

  System profiles (sign-in start, idle lock, firewall, Defender...) are never
  applied here; scripts/apply-system.ps1 has them, each with a dry run.

.PARAMETER DryRun
  Say what would be installed and deployed, and change nothing.
.PARAMETER Editor
  Also install Neovim and what NvChad needs (packages/editor.txt).
.PARAMETER Desktop
  Also install the everyday applications (packages/desktop.txt).
.PARAMETER Security
  Also install Malwarebytes and KeePassXC (packages/security.txt).
.PARAMETER Phone
  Also install KDE Connect, for the phone (packages/phone.txt).
.PARAMETER NoInstall
  Skip winget entirely; deploy only.
.PARAMETER ListSelectors
  Print the optional sets and whether each applies to this machine.
.PARAMETER NoStart
  Do not start GlazeWM or the wizard at the end.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Editor,
    [switch]$Desktop,
    [switch]$Security,
    [switch]$Phone,
    [switch]$NoInstall,
    [switch]$ListSelectors,
    [switch]$NoStart
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Apps.psm1') -Force
$root = Split-Path -Parent $PSScriptRoot
[void](Import-VivacStrings (Read-VivacSettings)['language'])

function Read-Manifest([string]$Path) {
    @([IO.File]::ReadAllLines((Join-Path $root $Path)) | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { $_.Trim() })
}

function Get-Selectors {
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $root 'data\selectors.tsv'))) {
        if ($line -match '^\s*(#|$)') { continue }
        $f = $line -split "`t"
        [pscustomobject]@{ Id = $f[0]; Manifest = $f[1]; Predicate = $f[2]; Flag = $f[3]; Label = $f[4] }
    }
}

# Facts, detected in memory: bootstrap must be able to say what applies before
# it has written anything.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vivac-facts-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
& (Join-Path $PSScriptRoot 'hardware-facts.ps1') | Set-Content -LiteralPath $scratch -Encoding ASCII
$facts = Read-VivacFacts @($scratch, (Get-VivacPaths).FactsOverride)
Remove-Item -LiteralPath $scratch -Force
Write-Host (T 'bootstrap.this_machine' @($facts['chassis'], $facts['gpu_vendors']))

if ($ListSelectors) {
    foreach ($s in Get-Selectors) {
        $status = T 'selector.applies'
        if (-not (Test-VivacPredicate $s.Predicate $facts)) { $status = T 'selector.needs' @($s.Predicate) }
        '{0,-10} {1,-10} {2}  [{3}]' -f $s.Id, $s.Flag, (T $s.Label), $status
    }
    return
}

$manifests = @('packages/base.txt')
$asked = @{ editor = $Editor; desktop = $Desktop; security = $Security; phone = $Phone }
foreach ($s in Get-Selectors) {
    if (-not $asked[$s.Id]) { continue }
    if (-not (Test-VivacPredicate $s.Predicate $facts)) {
        Write-Error (T 'selector.not_applicable' @($s.Id, $s.Predicate))
        exit 3
    }
    $manifests += $s.Manifest
}

if (-not $NoInstall) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw (T 'bootstrap.no_winget') }
    foreach ($m in $manifests) {
        foreach ($id in Read-Manifest $m) {
            $listed = winget list --id $id -e --accept-source-agreements 2>$null | Out-String
            if ($listed -match [regex]::Escape($id)) { Write-Host "  [installed]  $id"; continue }
            if ($DryRun) { Write-Host "  [install]    $id"; continue }
            Write-Host "  [install]    $id"
            winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
            # 0 installed; -1978335189 already installed; anything else is real.
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw (T 'bootstrap.install_failed' @($id, $LASTEXITCODE)) }
        }
    }
    # winget extends PATH for new shells only; this one learns it here so the
    # deploy below can find what was just installed.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

if (-not $DryRun) { & (Join-Path $PSScriptRoot 'hardware-facts.ps1') -Emit }
& (Join-Path $PSScriptRoot 'deploy.ps1') -DryRun:$DryRun

if ($DryRun -or $NoStart) {
    Write-Host (T 'bootstrap.next_steps')
    exit 0
}

# Flow Launcher writes its settings file on first start; the launcher theme
# and hotkey are merged into it, so it is started once and deployed again.
if (-not (Test-Path -LiteralPath (Join-Path (Get-VivacPaths).AppData 'FlowLauncher\Settings\Settings.json'))) {
    if (Start-VivacApp 'flow') {
        Start-Sleep -Seconds 4
        & (Join-Path $PSScriptRoot 'deploy.ps1') -Package flow
    }
}
if (-not (Test-VivacAppRunning 'glazewm')) { [void](Start-VivacApp 'glazewm') }
$marker = Join-Path (Get-VivacPaths).State 'welcome-done'
if (-not (Test-Path -LiteralPath $marker)) { & (Join-Path $root 'bin\vivac.ps1') welcome '-FirstRun' }
Write-Host (T 'bootstrap.next_steps')
exit 0
