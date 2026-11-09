<#
.SYNOPSIS
  vivac's sign-in screen: the greeter, alone on a desktop of its own.

.DESCRIPTION
  With automatic sign-in (apply-system.ps1 -AutoLogin) Windows opens the
  session by itself and everything starts at once: Explorer, the window
  manager, the bar, every program in the Run keys. The task
  \vivac\lock-at-signin runs this so that none of it is seen: it makes a
  desktop of its own (lib\Greeter.psm1), covers it in the theme's base
  colour, switches the screen to it and opens the greeter there (the lock in
  its sign-in dress, lib\Surfaces.psm1). Whatever starts meanwhile does so on
  the programs' desktop, unseen and out of reach. The account's password
  unlocks (checked with Windows, kept nowhere); the screen then switches back
  to the desktop, with everything already loaded.

  Windows Hello's prompt is not offered here: it is a window of Windows' own,
  drawn on the programs' desktop, over a greeter it does not belong to. The
  PIN still works on Windows' own lock (Win+L, Ctrl+Alt+Del).

  The screen is never left on an empty desktop:
    - a watchdog process on the programs' desktop brings that desktop back
      and locks with Windows' own lock if this process dies;
    - a greeter that has not drawn in 60 s gives way to Windows' own lock,
      and so does a failure anywhere;
    - Ctrl+Alt+Del (Windows' secure screen) is honoured: the greeter steps
      aside and Windows' own lock takes over;
    - the file %LOCALAPPDATA%\vivac\no-greeter skips the greeter: Windows'
      own lock at once, for as long as the file is there.

  A sign-in the guard already settled (bin\vivac-signin-guard.ps1) or a
  fresh switch from Linux (lib\Switch.psm1) gets no greeter, as before.
  Failures go to %LOCALAPPDATA%\vivac\lock.log.

    (none)         do it (what the task runs)
    -Preview <s>   show the greeter for s seconds and come back, no password
                   asked: to see it, and to try the desktop switch. Takes no
                   token and locks nothing
    -Register      register \vivac\lock-at-signin to run this at sign-in, at
                   the normal level and high priority (the cover must beat
                   everything else that starts)
    -Unregister    remove that task
    -DryRun        with -Register: say what would be registered
#>
[CmdletBinding()]
param([switch]$Register, [switch]$Unregister, [switch]$DryRun, [int]$Preview = 0)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Switch.psm1') -Force
Import-Module (Join-Path $root 'lib\Greeter.psm1') -Force

$taskPath = '\vivac\'; $taskName = 'lock-at-signin'
if ($Unregister) {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    "removed: $taskPath$taskName"
    return
}
if ($Register) {
    # Normal level, like every task that runs a file the user can write.
    # High priority: at sign-in a dozen processes start together, and the
    # cover must be up before Explorer draws. The user's own name, as the
    # guard spells it: USERDOMAIN is not always set.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $argument = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($DryRun) { "would register: $taskPath$taskName (at sign-in, $user, normal level, priority 1) running conhost.exe $argument"; return }
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argument
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Limited -LogonType Interactive
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 1
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $set -Force | Out-Null
    "registered: $taskPath$taskName (at sign-in, normal level, high priority, runs $PSCommandPath)"
    return
}

$paths = Get-VivacPaths
$state = $paths.State
$log = Join-Path $state 'lock.log'
function Write-GreeterLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Force -Path $state | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0}  {1}' -f (Get-Date -Format s), $Text) -Encoding UTF8
    } catch { }
}
# Windows' own lock: what every failure falls back to. The gates point
# VIVAC_GREETER_LOCK at a script of their own (they never lock the machine
# they run on); a preview locks nothing.
$lockTool = $env:VIVAC_GREETER_LOCK
function Invoke-WindowsLock {
    if ($Preview -gt 0) { Write-GreeterLog 'preview: Windows'' own lock would come here'; return }
    if ($lockTool) { & $lockTool } else { & rundll32.exe user32.dll, LockWorkStation }
}
$native = Get-VivacDesktopNative
$desktop = Get-VivacGreeterDesktopName
function Restore-DefaultDesktop {
    try { if ($native::InputDesktopName() -eq $desktop) { [void]$native::SwitchToDefault() } } catch { }
}

if (Test-Path -LiteralPath (Join-Path $state 'no-greeter')) {
    Write-GreeterLog 'sign-in: no-greeter is set, Windows'' own lock instead'
    Invoke-WindowsLock
    return
}
if ($Preview -le 0) {
    $settled = $null
    try { $settled = Get-VivacSigninSettlement $state } catch { Write-GreeterLog "sign-in guard check failed: $_" }
    if ($settled) { Write-GreeterLog "sign-in settled by the guard ($settled): no greeter this time"; return }
    # Marked for the shared-settings pull (lib\Vivac.psm1): a theme or location
    # that arrives while the greeter is up waits for the unlock.
    [void](Set-VivacLockMarker 'start')
}

$outcome = 'failed'
$own = [IntPtr]::Zero
$ps = $null; $rs = $null
try {
    $own = $native::Create($desktop)
    $watch = Get-VivacGreeterWatchdogScript $PID $desktop $paths.LockMarker $log
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watch))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    [void][Diagnostics.Process]::Start($psi)

    # The greeter's thread: bound to the desktop before it owns a window,
    # then the cover, the switch, and the lock itself. What it finds out is
    # shared with this thread, which keeps time.
    $shared = [hashtable]::Synchronized(@{ CoverUp = $false; GreeterUp = $false; Done = $false; Outcome = $null; Error = $null })
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'UseNewThread'
    $rs.Open()
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($Root, $Own, $Desktop, $Shared, $Preview)
            $native = [VivacDesktopNative]
            try {
                $native::Bind($Own)
                Import-Module (Join-Path $Root 'lib\Surfaces.psm1') -Force
                Show-VivacLockCover
                $native::Switch($Own)
                $Shared.CoverUp = $true
                # The theme's wallpaper on Windows' own lock screen, should
                # the greeter hand over to it.
                try {
                    Import-Module (Join-Path $Root 'lib\Desktop.psm1') -Force
                    if (Test-VivacLockScreenManaged) { [void](Update-VivacLockScreen (Get-VivacWallpaper -Theme (Read-VivacTheme (Read-VivacSettings)['theme']))) }
                } catch { }
                $shown = { $Shared.GreeterUp = $true }.GetNewClosure()
                $Shared.Outcome = Show-VivacLock -Greeter -Desktop $Desktop -PasswordOnly -PreviewSeconds $Preview -OnShown $shown
            } catch {
                $Shared.Error = "$_"
                try { Hide-VivacLockCover } catch { }
            } finally {
                try { if ($native::InputDesktopName() -eq $Desktop) { [void]$native::SwitchToDefault() } } catch { }
                $Shared.Done = $true
            }
        }).AddArgument($root).AddArgument($own).AddArgument($desktop).AddArgument($shared).AddArgument($Preview)
    $handle = $ps.BeginInvoke()

    # Keeping time: a greeter that has not drawn in a minute gives way, so a
    # start that hangs anywhere (a module, a font, a picture) never leaves
    # the screen covered.
    $grace = 60
    $started = Get-Date
    while (-not $shared.Done) {
        Start-Sleep -Milliseconds 250
        if (-not $shared.GreeterUp -and ((Get-Date) - $started).TotalSeconds -gt $grace) {
            Write-GreeterLog "the greeter did not show in $grace s: Windows' own lock instead"
            break
        }
        if ($handle.IsCompleted -and -not $shared.Done) { break }
    }
    if ($shared.Error) { Write-GreeterLog "greeter failed: $($shared.Error)" }
    elseif ($shared.Done -and $shared.Outcome) { $outcome = [string]$shared.Outcome }
} catch {
    Write-GreeterLog "greeter could not start: $_"
} finally {
    Restore-DefaultDesktop
    # The lock itself hands over to Windows' lock on every way out but the
    # unlock; only a greeter that never got that far is locked from here.
    if ($outcome -eq 'failed') { Invoke-WindowsLock }
    if ($Preview -le 0) { Clear-VivacLockMarker }
    try { if ($ps -and -not $handle.IsCompleted) { [void]$ps.BeginStop($null, $null) } } catch { }
    Write-GreeterLog "sign-in: greeter ended ($outcome)"
}
# The greeter's thread may still be winding down: the process ends here
# regardless, and the watchdog sees it go.
[Environment]::Exit(0)
