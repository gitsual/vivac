<#
.SYNOPSIS
  Install and update programs with winget, elevated, without a UAC prompt.

.DESCRIPTION
    -Queue <verb> [-Id <id>] [-Follow]
                     asks for one winget job: upgrade (all, or one id) or
                     install (one id). Starts the task \vivac\winget, which
                     runs elevated, and with -Follow prints its output until
                     it ends, with winget's exit code as this one's
    -Run             what the task runs: every request waiting, in order

  Most installers ask for elevation; a winget run from the bar or a terminal
  then stops at a UAC prompt, and with the taskbar hidden that prompt is easy
  to miss while winget holds Windows' installer lock behind it. The task is
  registered once, elevated (scripts/register-winget.ps1), and runs
  elevated each time it is started, which a normal process may do.

  A request is a file of its own in %LOCALAPPDATA%\vivac\winget, written by a
  process that is not elevated, so the task trusts nothing in it: a verb from
  a fixed list and an id winget's catalog could hold, always from the winget
  source, never a manifest, a path or another argument.
#>
param(
    [ValidateSet('upgrade', 'install')][string]$Queue,
    [ValidatePattern('^[\w.+-]+$')][string]$Id,
    [switch]$Follow,
    [switch]$Run
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'vivac\winget'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Get-WingetArgs([string]$Line) {
    # The one place a request becomes a command line.
    if ($Line -eq 'upgrade') { return @('upgrade', '--all') }
    if ($Line -match '^(upgrade|install) ([\w.+-]+)$') { return @($Matches[1], '--id', $Matches[2], '--exact', '--source', 'winget') }
    $null
}

if ($Run) {
    $mutex = New-Object Threading.Mutex($false, 'Global\vivac-winget')
    if (-not $mutex.WaitOne(0)) { return }
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $winget = (Get-Command winget.exe).Source
        # A request may arrive while the last one runs: look again before leaving.
        for ($idle = 0; $idle -lt 3; $idle++) {
            foreach ($req in @(Get-ChildItem -LiteralPath $dir -Filter '*.req' | Sort-Object Name)) {
                $idle = 0
                $base = [IO.Path]::ChangeExtension($req.FullName, $null).TrimEnd('.')
                $line = (Get-Content -LiteralPath $req.FullName -Raw).Trim()
                Remove-Item -LiteralPath $req.FullName -Force
                $wa = Get-WingetArgs $line
                $code = 87
                if ($wa) {
                    $all = $wa + @('--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
                    & $winget @all 2>&1 | ForEach-Object { ([string]$_ -split "`r")[-1] } |
                        Where-Object { $_ -match '\w' } | Out-File -LiteralPath "$base.log" -Append -Encoding utf8
                    $code = $LASTEXITCODE
                } else { "rejected: $line" | Out-File -LiteralPath "$base.log" -Append -Encoding utf8 }
                [string]$code | Out-File -LiteralPath "$base.done" -Encoding ascii
            }
            Start-Sleep -Seconds 1
        }
        # Old answers nobody followed.
        Get-ChildItem -LiteralPath $dir -Include '*.log', '*.done' -Recurse |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
    } finally { $mutex.ReleaseMutex() }
    return
}

if ($Queue) {
    $line = $Queue
    if ($Id) { $line = "$Queue $Id" } elseif ($Queue -eq 'install') { throw 'vivac-winget: install needs -Id' }
    $base = Join-Path $dir ('{0:yyyyMMddHHmmssfff}-{1}' -f (Get-Date), $PID)
    Set-Content -LiteralPath "$base.tmp" -Value $line -Encoding ascii
    Move-Item -LiteralPath "$base.tmp" -Destination "$base.req"
    Start-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget'
    if (-not $Follow) { return }
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $seen = 0
    while ($true) {
        $done = Test-Path -LiteralPath "$base.done"
        if (Test-Path -LiteralPath "$base.log") {
            $lines = @(Get-Content -LiteralPath "$base.log" -Encoding UTF8)
            if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] | Write-Host; $seen = $lines.Count }
        }
        if ($done) { break }
        Start-Sleep -Milliseconds 500
    }
    exit [int](Get-Content -LiteralPath "$base.done" -Raw).Trim()
}
