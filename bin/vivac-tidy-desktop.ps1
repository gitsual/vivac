<#
.SYNOPSIS
  Keep the desktop free of shortcuts: they belong in the launcher.

.DESCRIPTION
  Installers drop a shortcut on the desktop, which a tiling session never
  shows. This moves each .lnk and .url off the desktops: one the Start menu
  already reaches goes to a backup, and one it does not goes into the Start
  menu first, so Flow Launcher and vivac's menu both still find it. One whose
  program is gone (a desktop carried over from another install) goes to the
  backup too: a dead entry in the menu is worse than none. Files and folders
  on the desktop are never touched, and nothing is deleted.

    (none)       one pass now
    -Watch       stay resident and tidy whatever lands later, a few seconds
                 after it lands (what the sign-in task runs)
    -Register    run -Watch at every sign-in, as \vivac\tidy-desktop, and
                 start it now
    -Unregister  remove that task and stop the watcher
    -DryRun      print what would move, move nothing

  The shared desktop (C:\Users\Public\Desktop) is only writable by an
  administrator; its shortcuts are left where they are, and logged, until
  the user is given write access to it.
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Register,
    [switch]$Unregister,
    [switch]$DryRun,
    # Tests point these at scratch folders.
    [string[]]$Desktops = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')),
    [string[]]$StartMenus = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')),
    [string]$Backup
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force

$paths = Get-VivacPaths
if (-not $Backup) { $Backup = Join-Path $paths.Backups 'desktop-shortcuts' }
$log = Join-Path $paths.State 'tidy-desktop.log'
$taskPath = '\vivac\'
$taskName = 'tidy-desktop'

function Write-TidyLog([string]$Line) {
    if ($DryRun) { $Line; return }
    $Line
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $log))
        Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Line) -Encoding UTF8
    } catch { }
}

# What a shortcut opens: the target of a .lnk with its arguments (two Steam
# games share Steam.exe), the URL of a .url.
$shell = New-Object -ComObject WScript.Shell
function Get-ShortcutKey([IO.FileInfo]$File) {
    try {
        if ($File.Extension -eq '.lnk') {
            $s = $shell.CreateShortcut($File.FullName)
            if (-not $s.TargetPath) { return $null }
            return ("$($s.TargetPath) $($s.Arguments)").Trim().ToLowerInvariant()
        }
        $url = @(Get-Content -LiteralPath $File.FullName -ErrorAction Stop | Where-Object { $_ -match '^URL=' }) | Select-Object -First 1
        if ($url) { return $url.Substring(4).Trim().ToLowerInvariant() }
    } catch { }
    $null
}

# A .lnk naming a file that is not there. One with no file target at all (a
# Store app, a shell folder) cannot be judged and counts as alive.
function Test-ShortcutBroken([IO.FileInfo]$File) {
    if ($File.Extension -ne '.lnk') { return $false }
    try { $t = $shell.CreateShortcut($File.FullName).TargetPath } catch { return $false }
    [bool]($t -and -not (Test-Path -LiteralPath $t))
}

function Get-Shortcuts([string[]]$Dirs, [switch]$Recurse) {
    foreach ($d in $Dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $d -File -Force -Recurse:$Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.lnk', '.url' }
    }
}

function Invoke-Tidy {
    $known = @{}
    foreach ($f in Get-Shortcuts $StartMenus -Recurse) {
        $k = Get-ShortcutKey $f
        if ($k) { $known[$k] = $true }
    }
    $stamp = Join-Path $Backup (Get-Date -Format 'yyyyMMdd')
    $userStart = $StartMenus[0]
    foreach ($f in @(Get-Shortcuts $Desktops)) {
        $k = Get-ShortcutKey $f
        # Already in the Start menu: the desktop copy is only clutter. Not
        # there, or unreadable: it becomes a Start menu entry, unless one by
        # that name exists, in which case it is kept aside rather than lost.
        $dest = $stamp
        $why = 'in Start'
        if (Test-ShortcutBroken $f) {
            $why = 'program gone'
        } elseif (-not ($k -and $known.ContainsKey($k)) -and -not (Test-Path -LiteralPath (Join-Path $userStart $f.Name))) {
            $dest = $userStart
            $why = 'added to Start'
        }
        $target = Join-Path $dest $f.Name
        if ($dest -eq $stamp -and (Test-Path -LiteralPath $target)) {
            $target = Join-Path $dest ('{0}-{1:HHmmss}{2}' -f $f.BaseName, (Get-Date), $f.Extension)
        }
        if ($DryRun) { Write-TidyLog "would move ($why): $($f.FullName) -> $target"; continue }
        try {
            [void](New-Item -ItemType Directory -Force -Path $dest)
            Move-Item -LiteralPath $f.FullName -Destination $target
            if ($k) { $known[$k] = $true }
            Write-TidyLog "moved ($why): $($f.FullName) -> $target"
        } catch [UnauthorizedAccessException] {
            Write-TidyLog "no write access, left: $($f.FullName)"
        } catch {
            Write-TidyLog "could not move $($f.FullName): $($_.Exception.Message)"
        }
    }
}

if ($Unregister) {
    if ($DryRun) { "would unregister $taskPath$taskName and stop its watcher"; return }
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match 'vivac-tidy-desktop\.ps1' -and $_.CommandLine -match '-Watch' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    "unregistered $taskPath$taskName"
    return
}

if ($Register) {
    # conhost --headless, as the bar's buttons use: no console window at
    # sign-in and none left open behind the session.
    $runner = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Watch"
    if ($DryRun) { "would register $taskPath$taskName (Logon): conhost.exe $runner"; return }
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $runner
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settingsObj = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Settings $settingsObj -Force | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    "registered $taskPath$taskName (Logon) and started it"
    return
}

if (-not $Watch -or $DryRun) { Invoke-Tidy; return }
# The watcher was found gone after a sign-in with nothing in the log: whatever
# ends it from here on says so first.
trap { Write-TidyLog "watcher stopped: $($_.Exception.Message)"; break }
# Resident: one failed pass (a desktop not mounted yet) must not end it.
try { Invoke-Tidy } catch { Write-TidyLog "pass failed: $($_.Exception.Message)" }

# Installers write a shortcut and then sometimes rewrite it; a pass a few
# seconds after the last change catches the final file, once. Change events
# do not come from every desktop: one redirected to a WSL disk
# (\\wsl.localhost\...) sends none, and one not mounted yet at sign-in cannot
# be watched at all. So the desktops are also looked at every 15 s, which
# only lists them; the full pass runs when a shortcut is there.
$watched = @{}
function Start-Watchers {
    foreach ($d in $Desktops) {
        if ($watched.ContainsKey($d) -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        try {
            $w = New-Object IO.FileSystemWatcher $d
            $w.IncludeSubdirectories = $false
            $w.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'
            $w.EnableRaisingEvents = $true
            foreach ($e in 'Created', 'Renamed', 'Changed') { [void](Register-ObjectEvent $w $e -SourceIdentifier "tidy-$e-$([guid]::NewGuid())") }
            $watched[$d] = $w
        } catch { }
    }
}
Start-Watchers
$pending = $false
$idle = 0
while ($true) {
    $ev = Wait-Event -Timeout 5
    if ($ev) {
        Get-Event | Remove-Event
        $pending = $true
        continue
    }
    $idle++
    if (-not $pending -and $idle -ge 3) {
        $idle = 0
        try {
            Start-Watchers
            $pending = [bool]@(Get-Shortcuts $Desktops).Count
        } catch { Write-TidyLog "look failed: $($_.Exception.Message)" }
    }
    if ($pending) {
        $pending = $false
        try { Invoke-Tidy } catch { Write-TidyLog "pass failed: $($_.Exception.Message)" }
    }
}
