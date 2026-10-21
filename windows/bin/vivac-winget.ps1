<#
.SYNOPSIS
  Update programs with winget, elevated, without a UAC prompt; install them
  with winget as usual (with the installer's own prompt).

.DESCRIPTION
    -Queue upgrade [-Id <id>] [-Follow]
                     asks for one winget update (all, or one installed id).
                     Starts the task \vivac\winget, which runs elevated, and
                     with -Follow prints its output until it ends, with
                     winget's exit code as this one's
    -Queue install -Id <id> [-Follow]
                     runs winget install here, not elevated: installing
                     something new is a decision Windows' own prompt confirms
    -Run             what the task runs: every request waiting, in order

  Most updaters ask for elevation; a winget run from the bar or a terminal
  then stops at a UAC prompt, and with the taskbar hidden that prompt is easy
  to miss while winget holds Windows' installer lock behind it.

  What the task runs is a copy of this file in C:\Program Files\vivac\winget
  (scripts/protect-tasks.ps1), never the repository's, which the user can
  write without elevation. Requests are files the user drops into
  C:\ProgramData\vivac\winget\inbox, the only folder there the user may
  write to; answers go to ...\winget\out, which only the task writes. The
  task trusts nothing in a request: a verb from a fixed list and an id
  winget's catalog could hold, always from the winget source, and winget
  itself from its own package folder, never from PATH. Only updates of what
  is already installed run this way.
#>
param(
    [ValidateSet('upgrade', 'install')][string]$Queue,
    [ValidatePattern('^[\w.+-]+$')][string]$Id,
    [switch]$Follow,
    [switch]$Run
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:ProgramData 'vivac\winget'
$inbox = Join-Path $data 'inbox'
$outbox = Join-Path $data 'out'
$wingetFlags = @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
# "No applicable update": --all found nothing to do, which is not a failure.
$nothingToDo = -1978335189
# "Update not supported": the publisher updates it from inside the program
# (Android Studio, say). Pinned, so winget stops listing it for ever.
$selfUpdating = -1978334956

function Get-WingetArgs([string]$Line) {
    # The one place a request becomes a command line.
    if ($Line -eq 'upgrade') { return @('upgrade', '--all') }
    if ($Line -match '^upgrade ([\w.+-]+)$') { return @('upgrade', '--id', $Matches[1], '--exact', '--source', 'winget') }
    $null
}

# winget from its own package folder (under Program Files\WindowsApps, which
# only the system writes), never whatever PATH finds first.
function Get-WingetPath {
    $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) { throw 'vivac-winget: App Installer (winget) is not installed' }
    $exe = Join-Path $pkg.InstallLocation 'winget.exe'
    if ($exe -notlike "$env:ProgramFiles\WindowsApps\*" -or -not (Test-Path -LiteralPath $exe)) { throw "vivac-winget: unexpected winget at $exe" }
    $exe
}

# The ids in winget's upgrade tables. --all leaves out the packages whose
# manifest asks to be updated by name (RequireExplicitUpgrade: Android Studio,
# say), listed in a table of their own, so an update of everything names
# them one by one afterwards. The header is in the system's language: the id
# is the second column, found by where the header's words start. Each id is
# checked here, as it reaches a command line.
function Get-WingetPendingIds([string]$Winget) {
    $text = (& $Winget @('upgrade', '--accept-source-agreements', '--disable-interactivity') 2>$null | Out-String)
    $lines = @($text -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() })
    $ids = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{10,}$') { continue }
        $starts = @([regex]::Matches($lines[$i - 1], '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 4) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ($line.Length -le $starts[2]) { break }
            $id = $line.Substring($starts[1], $starts[2] - $starts[1]).Trim()
            if ($id -notmatch '^[\w.+-]+$') { break }
            $ids += $id
        }
    }
    @($ids | Select-Object -Unique)
}

function Test-NoReparse([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if ((Test-Path -LiteralPath $p) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $parent = [IO.Path]::GetDirectoryName($p)
        if ($parent -eq $p) { break }
        $p = $parent
    }
    $true
}

if ($Run) {
    # Only the protected copy answers requests.
    if ($PSCommandPath -notlike "$env:ProgramFiles\vivac\*") { throw 'vivac-winget: -Run only from the protected copy (scripts/protect-tasks.ps1)' }
    if (-not (Test-NoReparse $inbox) -or -not (Test-NoReparse $outbox)) { throw 'vivac-winget: the queue goes through a link' }
    $mutex = New-Object Threading.Mutex($false, 'Global\vivac-winget')
    if (-not $mutex.WaitOne(0)) { return }
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $winget = Get-WingetPath
        # A request may arrive while the last one runs: look again before leaving.
        for ($idle = 0; $idle -lt 3; $idle++) {
            $reqs = @(Get-ChildItem -LiteralPath $inbox -File -Filter '*.req' |
                    Where-Object { $_.Name -match '^\d{17}-\d+\.req$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Sort-Object Name)
            foreach ($req in $reqs) {
                $idle = 0
                $name = [IO.Path]::GetFileNameWithoutExtension($req.Name)
                $base = Join-Path $outbox $name
                $line = ''
                if ($req.Length -le 200) { $line = ([IO.File]::ReadAllText($req.FullName)).Trim() }
                Remove-Item -LiteralPath $req.FullName -Force
                $wa = Get-WingetArgs $line
                $code = 87
                if ($wa) {
                    $runs = @(, $wa)
                    $code = 0
                    for ($r = 0; $r -lt $runs.Count; $r++) {
                        $all = $runs[$r] + @('--silent') + $wingetFlags
                        & $winget @all 2>&1 | ForEach-Object { ([string]$_ -split "`r")[-1] } |
                            Where-Object { $_ -match '\w' } | Out-File -LiteralPath "$base.log" -Append -Encoding utf8
                        $rc = $LASTEXITCODE
                        if ($rc -eq $selfUpdating -and $runs[$r] -contains '--id') {
                            & $winget @('pin', 'add', '--id', $runs[$r][2], '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') 2>&1 |
                                ForEach-Object { ([string]$_ -split "`r")[-1] } | Where-Object { $_ -match '\w' } | Out-File -LiteralPath "$base.log" -Append -Encoding utf8
                        } elseif ($rc -notin 0, $nothingToDo) { $code = $rc }
                        if ($r -eq 0 -and $line -eq 'upgrade') {
                            foreach ($one in (Get-WingetPendingIds $winget)) { $runs += , @('upgrade', '--id', $one, '--exact', '--source', 'winget') }
                        }
                    }
                } else { "rejected: only updates run without a prompt" | Out-File -LiteralPath "$base.log" -Append -Encoding utf8 }
                [string]$code | Out-File -LiteralPath "$base.done" -Encoding ascii
            }
            Start-Sleep -Seconds 1
        }
        # Old answers nobody followed (only the task's own folder, never recursively).
        Get-ChildItem -LiteralPath $outbox -File | Where-Object { $_.Name -match '^\d{17}-\d+\.(log|done)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } finally { $mutex.ReleaseMutex() }
    return
}

if ($Queue) {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $direct = $Queue -eq 'install' -or -not (Test-Path -LiteralPath $inbox) -or
        -not (Get-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget' -ErrorAction SilentlyContinue)
    if ($Queue -eq 'install' -and -not $Id) { throw 'vivac-winget: install needs -Id' }
    if ($direct) {
        # Not elevated: the installer asks for elevation itself, if it needs it.
        $wa = @($Queue)
        if ($Id) { $wa += @('--id', $Id, '--exact', '--source', 'winget') } else { $wa += '--all' }
        $winget = Get-WingetPath
        & $winget @($wa + $wingetFlags)
        $code = $LASTEXITCODE
        if ($code -eq $nothingToDo) { $code = 0 }
        if ($Queue -eq 'upgrade' -and -not $Id) {
            foreach ($one in (Get-WingetPendingIds $winget)) {
                & $winget @(@('upgrade', '--id', $one, '--exact', '--source', 'winget') + $wingetFlags)
                if ($LASTEXITCODE -eq $selfUpdating) { & $winget pin add --id $one --exact --source winget --accept-source-agreements --disable-interactivity }
                elseif ($LASTEXITCODE -notin 0, $nothingToDo) { $code = $LASTEXITCODE }
            }
        }
        exit $code
    }
    $line = $Queue
    if ($Id) { $line = "$Queue $Id" }
    $name = '{0:yyyyMMddHHmmssfff}-{1}' -f (Get-Date), $PID
    [IO.File]::WriteAllText((Join-Path $inbox "$name.req"), $line)
    Start-ScheduledTask -TaskPath '\vivac\' -TaskName 'winget'
    if (-not $Follow) { return }
    $base = Join-Path $outbox $name
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
