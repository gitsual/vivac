<#
.SYNOPSIS
  Keep the bar up and drawn: restart Zebar when it dies or comes up blank.

.DESCRIPTION
  With the Windows taskbar hidden the bar is the only way back to a
  minimized window, so a bar that is gone, or there but blank, strands the
  session. The bar proves it is drawn by stamping %LOCALAPPDATA%\vivac\
  bar.alive every half minute, and only while its stylesheet is applied and
  its workspaces are in place (static/zebar/vivac/bar.js). This watcher
  restarts Zebar (Restart-VivacBar in lib/Apps.psm1) when zebar.exe is gone
  while GlazeWM runs, or when the stamp is older than two and a half
  minutes. While the bar is drawn it keeps a copy of the pack as the last
  good one (lib/Bar.psm1); when two restarts in a row do not bring the
  stamp back, that copy is put back. Restarts that still fail are retried
  at longer and longer intervals, never more than once a minute.

    -Watch       stay resident (what the sign-in task runs)
    -Register    run -Watch at every sign-in, as \vivac\bar-watch, at the
                 normal level (an elevated Zebar could not be driven by the
                 rest of vivac), and start it now
    -Unregister  remove that task and stop the watcher
    (none)       one check now, restarting the bar if it needs it

  Nothing is checked while Windows' own lock screen is up: the session
  is not drawn then, and the bar may be paused with it.
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Register,
    [switch]$Unregister,
    [switch]$DryRun
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Apps.psm1') -Force
Import-Module (Join-Path $root 'lib\Bar.psm1') -Force

$paths = Get-VivacPaths
$alive = Join-Path $env:LOCALAPPDATA 'vivac\bar.alive'
$log = Join-Path $paths.State 'bar-watch.log'
$taskPath = '\vivac\'
$taskName = 'bar-watch'
$staleAfter = [TimeSpan]::FromSeconds(150)
# Restarts in a row that did not bring the stamp back, and whether the last
# good pack was already put back for them.
$script:failures = 0
$script:restored = $false

function Write-WatchLog([string]$Line) {
    $Line
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $log))
        Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Line) -Encoding UTF8
    } catch { }
}

if ($Unregister) {
    if ($DryRun) { "would remove $taskPath$taskName"; return }
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'vivac-bar-watch\.ps1' -and $_.CommandLine -match '-Watch' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    "removed $taskPath$taskName"
    return
}

if ($Register) {
    $runner = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Watch"
    if ($DryRun) { "would register $taskPath$taskName (Logon, Limited): conhost.exe $runner"; return }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $runner
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settingsObj = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsObj -Force | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    "registered $taskPath$taskName (Logon) and started it"
    return
}

# Why the bar needs a restart, or $null when it does not. $Since is when the
# current Zebar was started (by us or anyone): a new one gets the stale
# window to stamp before it is judged.
function Get-BarTrouble([datetime]$Since) {
    if (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) { return $null }
    if (-not (Test-VivacAppRunning 'glazewm')) { return $null }
    $zebar = @(Get-Process -Name zebar -ErrorAction SilentlyContinue)
    if (-not $zebar.Count) { return 'zebar is not running' }
    $started = ($zebar | Measure-Object -Property StartTime -Maximum).Maximum
    if ($Since -gt $started) { $started = $Since }
    $now = Get-Date
    if ($now - $started -lt $staleAfter) { return $null }
    if (-not (Test-Path -LiteralPath $alive)) { return 'the bar never stamped bar.alive' }
    $age = $now - (Get-Item -LiteralPath $alive).LastWriteTime
    if ($age -gt $staleAfter) { return ('the bar last stamped {0:N0} s ago' -f $age.TotalSeconds) }
    $null
}

function Invoke-BarCheck([datetime]$Since) {
    $trouble = Get-BarTrouble $Since
    if (-not $trouble) { return $false }
    if ($DryRun) { "would restart the bar: $trouble"; return $true }
    # Two restarts that did not bring it back: the pack itself is at fault.
    if ($script:failures -ge 2 -and -not $script:restored) {
        Write-WatchLog "putting the last good bar back: $trouble"
        $script:restored = $true
        if (Restore-VivacBarLastGood) { return $true }
        Write-WatchLog 'no last good bar to put back'
    }
    Write-WatchLog "restarting the bar: $trouble"
    if (-not (Restart-VivacBar)) { Write-WatchLog 'zebar.exe not found' }
    $true
}

# While the bar is drawn, the pack it runs is the one to fall back on.
function Update-LastGood {
    if (-not (Test-VivacBarProven)) { return }
    if (Test-VivacBarLastGoodStale) {
        if (Save-VivacBarLastGood) { Write-WatchLog 'kept the bar as the last good one' }
    }
}

if (-not $Watch) { [void](Invoke-BarCheck ([datetime]::MinValue)); return }

Write-WatchLog "watching (pid $PID)"
$lastRestart = [datetime]::MinValue
while ($true) {
    try {
        # Back off when restarts keep failing: one, two, four... minutes,
        # capped at fifteen, so a Zebar that cannot draw is not hammered.
        $wait = [Math]::Min(15, [Math]::Pow(2, [Math]::Max(0, $script:failures - 1)))
        if ($script:failures -eq 0 -or (Get-Date) - $lastRestart -ge [TimeSpan]::FromMinutes($wait)) {
            if (Invoke-BarCheck $lastRestart) {
                $script:failures++
                $lastRestart = Get-Date
            } elseif ($script:failures -and (Get-Date) - $lastRestart -ge $staleAfter) {
                Write-WatchLog 'the bar is back'
                $script:failures = 0
                $script:restored = $false
            }
            if ($script:failures -eq 0) { Update-LastGood }
        }
    } catch {
        Write-WatchLog "check failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 10
}
