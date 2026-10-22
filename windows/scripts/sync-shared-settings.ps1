<#
.SYNOPSIS
  Sign-in: bring the other OS's choices in from the shared settings file.

.DESCRIPTION
  Reads the optional shared key=value file named by the shared_settings key of
  %APPDATA%\vivac\settings and applies the theme, weather location and UI
  language found there (the Linux side of vivac reads and writes the same
  file). What a local change could not send while the share was away goes out
  first, from the local value. Foreign keys, CR, a BOM and malformed lines are
  ignored; a value that fails validation is reported and skipped.

  No sharing configured, no file there, or a busy lock is silence and exit 0.
  Equal values change and reload nothing.

.PARAMETER Pull
  Required: the one thing this script does.
.PARAMETER WaitForShare
  Seconds to wait for the shared folder to appear (the share is linked a
  little after sign-in), default 0.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Pull,
    [int]$WaitForShare = 0,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $Pull -or $Rest) {
    [Console]::Error.WriteLine('Usage: scripts\sync-shared-settings.ps1 -Pull [-WaitForShare SECONDS]')
    exit 2
}
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force

try {
    $shared = Get-VivacSharedPath
    if (-not $shared) { exit 0 }
    $folder = Split-Path -Parent $shared
    $limit = [DateTime]::UtcNow.AddSeconds($WaitForShare)
    while (-not (Test-Path -LiteralPath $folder -PathType Container) -and [DateTime]::UtcNow -lt $limit) {
        Start-Sleep -Milliseconds 500
    }
    $changed = @(Invoke-VivacSharedPull)
    $applyTheme = $env:VIVAC_APPLY_THEME
    if (-not $applyTheme) { $applyTheme = Join-Path $PSScriptRoot 'apply-theme.ps1' }
    $deploy = $env:VIVAC_DEPLOY
    if (-not $deploy) { $deploy = Join-Path $PSScriptRoot 'deploy.ps1' }
    # Theme and location need the desktop reloaded, which restarts the resident
    # host. While it holds the lock (the cover and greeter of an automatic
    # sign-in, or the lock screen) that would kill the lock: the change waits,
    # recorded, for the first pull after the unlock.
    $reload = @(@($changed) + @(Get-VivacDeferredKeys) | Where-Object { $_ -in 'theme', 'weather_location' } | Select-Object -Unique)
    if ($reload.Count -and (Get-VivacLockMarker)) {
        Set-VivacDeferredKeys $reload
        Write-VivacSharedLog "session is locked: $($reload -join ', ') applied after the unlock"
    } else {
        Set-VivacDeferredKeys @()
        if ($reload -contains 'theme') { & $applyTheme }
        elseif ($reload -contains 'weather_location') { & $deploy -Package zebar }
    }
} catch {
    [Console]::Error.WriteLine("sync-shared-settings: $_")
}
exit 0
