<#
.SYNOPSIS
  The resident host of vivac's surfaces, so a key opens one at once.

.DESCRIPTION
  Starting Windows PowerShell, loading WPF and building a window costs about
  two seconds, which is not what a key should feel like. This process pays it
  once, at sign-in (GlazeWM starts it), and then waits on a named pipe for a
  verb: menu, help, power, theme, sound, bluetooth, network, updates,
  clipboard, lock, or quit.

  The bindings write the verb with cmd.exe, which starts in milliseconds:

      cmd /c echo help>\\.\pipe\vivac-<user> 2>nul || <start bin\vivac.ps1 help>

  so when this host is not running the key still works, only slower.

  Only the verbs above are understood; anything else read from the pipe is
  ignored. The pipe keeps the default security of Windows named pipes, which
  lets other accounts read but only its owner (and administrators) write.

  Pressing a surface's key while it is open closes it, as rofi does.
#>
# -LockAtStart: started at sign-in after an automatic Windows sign-in; the
# screens are covered at once and vivac's greeter (the lock, in the source's
# ReGreet frame) opens as soon as it can.
param([switch]$LockAtStart)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
Import-Module (Join-Path $root 'lib\Security.psm1') -Force
Import-Module (Join-Path $root 'lib\Bluetooth.psm1') -Force
Import-Module (Join-Path $root 'lib\Network.psm1') -Force
Import-Module (Join-Path $root 'lib\Updates.psm1') -Force
Import-Module (Join-Path $root 'lib\Toasts.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$created = $false
$script:HostMutex = New-Object System.Threading.Mutex($true, 'Local\vivac-daemon', [ref]$created)
if (-not $created) { exit 0 }

# Started by GlazeWM, this process runs above the normal integrity level, and
# a normal one can read neither its command line nor stop it; the id is left
# here for scripts/deploy.ps1 (Restart-VivacDaemon) to find it by.
$pidFile = Join-Path (Get-VivacPaths).State 'daemon.pid'
# A verb that fails has nowhere to say so on screen; it says so here.
function Write-DaemonLog([string]$Text) {
    try {
        $log = Join-Path (Get-VivacPaths).State 'daemon.log'
        $dir = Split-Path -Parent $log
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $log -Value ('{0}  {1}' -f (Get-Date -Format s), $Text) -Encoding UTF8
    } catch { }
}
# A failure here must not keep the cover from going up: the pid file only
# helps deploy find this host.
try { Write-VivacFile -Path $pidFile -Text "$PID`n" } catch { Write-DaemonLog "could not write the pid file: $_" }
if ($LockAtStart) { [void](Set-VivacLockMarker 'start'); Show-VivacLockCover } else { Reset-VivacLockMarker }
# The other OS's theme, location and language, when sharing is configured:
# a process of its own, so a share that is not there yet delays nothing here.
try { [void](Start-VivacSharedSync) } catch { Write-DaemonLog "shared settings pull failed to start: $_" }

$pipeName = Get-VivacPipeName
$queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'lib\VivacPipe.cs')))
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$pipeSddl = "D:P(A;;GA;;;$sid)(A;;GA;;;SY)(A;;GA;;;BA)S:(ML;;NW;;;LW)"

# The pipe is read on a runspace of its own, which only ever enqueues text;
# everything that touches a window happens on this thread, from the timer.
$reader = [PowerShell]::Create()
[void]$reader.AddScript({
        param($Queue, $Name, $Sddl)
        # The next instance is created as soon as one is connected, before the
        # connected one is read: a key pressed in between must find the pipe
        # open, or cmd.exe falls back to the two-second start.
        $new = { [VivacPipe]::Create($Name, $Sddl, 4) }
        $server = & $new
        while ($true) {
            try {
                $server.WaitForConnection()
                $connected = $server
                $server = & $new
                try {
                    $text = (New-Object IO.StreamReader($connected)).ReadToEnd()
                    foreach ($line in ($text -split "`r?`n")) {
                        $verb = $line.Trim().ToLowerInvariant()
                        if ($verb) { $Queue.Enqueue($verb) }
                    }
                } finally { $connected.Dispose() }
            } catch {
                Start-Sleep -Milliseconds 200
                try { $server.Dispose() } catch { }
                $server = & $new
            }
        }
    }).AddArgument($queue).AddArgument($pipeName).AddArgument($pipeSddl)
$pending = $reader.BeginInvoke()

# Each surface still runs modally (ShowDialog), as it does when started on its
# own: its key handlers read the variables of the function that built it, and
# those only live while that function is on the stack. The modal loop keeps
# pumping this thread's timer, so the pipe is still served while one is open.
$open = @{}
# A theme or location that came in from the shared file while a lock was up is
# waiting; the session is open again, so the pull that applies it runs now.
function Resume-SharedSync {
    try { if (@(Get-VivacDeferredKeys).Count) { [void](Start-VivacSharedSync) } } catch { Write-DaemonLog "shared settings resume failed: $_" }
}
function Invoke-Verb([string]$Verb) {
    if ($Verb -eq 'quit') {
        foreach ($w in @($open.Values)) { try { $w.Close() } catch { } }
        [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        return
    }
    if ($Verb -eq 'lock') { try { Invoke-VivacLock } finally { Resume-SharedSync }; return }
    # Only ever queued by -LockAtStart: the lock, dressed as the greeter.
    # Whatever happens to the greeter, the cover put up at start comes down:
    # a sign-in must never end behind blank windows.
    if ($Verb -eq 'greet') { try { Invoke-VivacLock -Greeter } finally { Hide-VivacLockCover; Clear-VivacLockMarker; Resume-SharedSync }; return }
    if (@('menu', 'help', 'power', 'theme', 'sound', 'bluetooth', 'network', 'updates', 'clipboard', 'security') -notcontains $Verb) { return }
    $current = $open[$Verb]
    if ($current -and $current.IsVisible) { $current.Close(); return }
    switch ($Verb) {
        'menu'  {
            Show-Menu -Registry $open
            # The applications are listed again once the menu is gone, so
            # one installed meanwhile is there the next time.
            $script:refreshApps = $true
        }
        'help'  { Show-Help -Registry $open }
        'power' { Show-Power -Registry $open }
        'theme' { Show-ThemePicker -Registry $open }
        'sound' { Show-Sound -Registry $open }
        'bluetooth' { Show-Bluetooth -Registry $open }
        'network' { Show-Network -Registry $open }
        'updates' { Show-Updates -Registry $open }
        'clipboard' { Show-Clipboard -Registry $open }
        'security' { Show-Security -Registry $open }
    }
}

# Built once and thrown away: the first real window then opens without
# paying for compiling the XAML parser and the module's code paths. The
# Start menu's application list is read here too, once.
Update-VivacStartApps
Import-VivacAudio
foreach ($warm in (Show-Sound -NoShow), (Show-Menu -NoShow), (Show-Help -NoShow), (Show-Power -NoShow), (Show-ThemePicker -NoShow)) { $warm.Close() }
# Defender answers its first question of a process in about three seconds,
# the next ones at once: asked here, the security surface opens like the rest.
(Show-Security -NoShow).Close()
(Show-Bluetooth -NoShow).Close()
$loadingVerbs = @('menu', 'help', 'power', 'theme', 'sound', 'bluetooth', 'network', 'updates', 'clipboard', 'security')
try { Import-VivacLoading } catch { }
(Show-Network -NoShow).Close()
(Show-Updates -NoShow).Close()
$script:refreshApps = $false

# The taskbar, when apply-system.ps1 -Taskbar asked for it gone. Auto-hide
# alone still slides it in at the bottom edge, and Explorer shows it again
# whenever it restarts, so its windows (one per monitor) are hidden here and
# checked again every couple of seconds. scripts/uninstall.ps1 shows them.
Add-Type -Namespace VivacHost -Name Shell -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
$taskbarMarker = Join-Path (Get-VivacPaths).State 'hide-taskbar'
function Hide-Taskbar {
    if (-not (Test-Path -LiteralPath $taskbarMarker)) { return }
    foreach ($cls in 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd') {
        $h = [IntPtr]::Zero
        while (($h = [VivacHost.Shell]::FindWindowEx([IntPtr]::Zero, $h, $cls, $null)) -ne [IntPtr]::Zero) {
            if ([VivacHost.Shell]::IsWindowVisible($h)) { [void][VivacHost.Shell]::ShowWindow($h, 0) }
        }
    }
}
Hide-Taskbar
$shellTimer = New-Object Windows.Threading.DispatcherTimer
$shellTimer.Interval = [TimeSpan]::FromSeconds(2)
$shellTimer.Add_Tick({ try { Hide-Taskbar } catch { } })
$shellTimer.Start()

# The keyboard, watched by one low-level hook, for two things Windows would
# otherwise answer with surfaces of its own:
#
# - The Windows key. With Win as the modifier, Win+R opens vivac's menu
#   instead of Windows' Run box, Win+V vivac's clipboard history, Win+L
#   vivac's lock, Win on its own nothing at all (no Start menu), and Win with
#   any other key is the window manager's (or Windows' own shortcut). Windows is
#   not shown the Win key until it is known what it is for; see the comment
#   in the callback. GlazeWM reads the modifiers with GetKeyState, which the
#   injected press updates.
# - The volume keys. They are taken before Windows sees them, the volume is
#   set here through the Core Audio API (lib/VivacAudio.cs), and vivac's own indicator shows it,
#   so Windows' flyout never appears.
#
# The hook is C# end to end (lib/VivacKeys.cs): it runs on every key of the session and must
# never wait on PowerShell. It only counts and flags; the timer below acts.
# Low-level hooks are called newest first and GlazeWM swallows the keys it
# binds, so this hook is put back in front whenever GlazeWM restarts.
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'lib\VivacKeys.cs'))) -Language CSharp

$script:winMask = (Read-VivacSettings)['mod'] -eq 'lwin'
Import-VivacAudio
[VivacKeys]::MaskWin = $script:winMask
[VivacKeys]::TakeVolume = $true
[void][VivacKeys]::Install()
$script:glazePid = @(Get-Process glazewm -ErrorAction SilentlyContinue | Where-Object { $_.Path -notmatch '\\cli\\' } | ForEach-Object { $_.Id }) -join ','
# The hook is also put back every half minute, as the key guard does with its
# own: Windows drops a low-level hook without a word if it is ever slow to
# answer (a garbage collection of this process pauses its thread too), and
# Win+R then did nothing until the next sign-in.
$script:hookTicks = 0
$hookTimer = New-Object Windows.Threading.DispatcherTimer
$hookTimer.Interval = [TimeSpan]::FromSeconds(3)
$hookTimer.Add_Tick({
        $script:hookTicks++
        $now = @(Get-Process glazewm -ErrorAction SilentlyContinue | Where-Object { $_.Path -notmatch '\\cli\\' } | ForEach-Object { $_.Id }) -join ','
        if ($now -ne $script:glazePid -or $script:hookTicks % 10 -eq 0) {
            $script:glazePid = $now
            if (-not [VivacKeys]::Reinstall()) { Write-DaemonLog 'the keyboard hook could not be put back' }
        }
    })
$hookTimer.Start()

# A dropped hook is also noticed at the first key it misses, so the key after
# it works again. Raw input reports every key to this window as well, and
# Windows never takes it away for being slow; a key it reports that the hook
# was not shown (by its input time) means the hook is gone, and it is put
# back there and then. Keys typed into an elevated window are not shown to
# the hook either: those put it back at most every few seconds, harmlessly.
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class VivacRawKeys : NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    private struct RawInputDevice { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);
    [DllImport("user32.dll")] private static extern int GetMessageTime();
    private static int last = 0;
    private static bool any = false;
    public static int Last { get { return Thread.VolatileRead(ref last); } }
    public static bool Any { get { return any; } }
    public readonly bool Registered;
    public VivacRawKeys() {
        CreateParams cp = new CreateParams();
        cp.Parent = new IntPtr(-3);
        CreateHandle(cp);
        // Generic desktop keyboard, delivered while this window is not in
        // front (RIDEV_INPUTSINK).
        RawInputDevice[] d = { new RawInputDevice { UsagePage = 1, Usage = 6, Flags = 0x100, Target = Handle } };
        Registered = RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RawInputDevice)));
    }
    protected override void WndProc(ref Message m) {
        // WM_INPUT; its message time is the key's input time, whenever this
        // thread gets round to reading it.
        if (m.Msg == 0x00FF) { Thread.VolatileWrite(ref last, GetMessageTime()); any = true; }
        base.WndProc(ref m);
    }
}
'@
$script:rawKeys = New-Object VivacRawKeys
if (-not $script:rawKeys.Registered) { Write-DaemonLog 'raw keyboard input could not be registered: a dropped hook waits for the half-minute check' }
$script:hookFixedAt = [Environment]::TickCount - 10000
$script:hookFixes = 0
$script:rawFixedFor = 0
$hookWatch = New-Object Windows.Threading.DispatcherTimer
$hookWatch.Interval = [TimeSpan]::FromMilliseconds(250)
$hookWatch.Add_Tick({
        if (-not [VivacRawKeys]::Any) { return }
        $now = [Environment]::TickCount
        $raw = [VivacRawKeys]::Last
        # A missed key puts the hook back once, not on every tick until the next key.
        if ($raw -ne $script:rawFixedFor -and $raw - [VivacKeys]::LastSeen -gt 200 -and $now - $script:hookFixedAt -gt 3000) {
            $script:rawFixedFor = $raw
            $script:hookFixedAt = $now
            $script:hookFixes++
            if (-not [VivacKeys]::Reinstall()) { Write-DaemonLog 'the keyboard hook could not be put back' }
            # Counted, not logged each time: an elevated window in front
            # does this on every few seconds of typing.
            if ($script:hookFixes -eq 1 -or $script:hookFixes % 100 -eq 0) { Write-DaemonLog "keyboard hook missed a key and was put back ($($script:hookFixes) so far)" }
        }
    })
$hookWatch.Start()

# vivac's volume indicator, built once and shown on each change.
$script:osd = New-VivacVolumeOsd

# The clipboard history behind Win+V, the counterpart of the source's
# cliphist. Windows tells a listening window each time anything is copied; a
# message-only window here only counts the notices, and the timer reads the
# clipboard on this thread, the one WPF's clipboard calls must run on. The
# history is kept in memory and nowhere else (see Add-VivacClipboardEntry).
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class VivacClipWatch : NativeWindow {
    [DllImport("user32.dll", SetLastError = true)] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    private static int changes = 0;
    public static bool TakeChanges() { return Interlocked.Exchange(ref changes, 0) > 0; }
    public VivacClipWatch() {
        CreateParams cp = new CreateParams();
        cp.Parent = new IntPtr(-3);
        CreateHandle(cp);
        AddClipboardFormatListener(Handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x031D) Interlocked.Increment(ref changes);
        base.WndProc(ref m);
    }
}
'@
$script:clipWatch = New-Object VivacClipWatch
try { Add-VivacClipboardEntry } catch { }
($w = Show-Clipboard -NoShow).Close()

# Other programs' notifications, read once a second from Windows' record of
# them and drawn as vivac's cards (lib/Toasts.psm1). Only once apply-system
# -Toasts has turned Windows' banners off; until then this only keeps count.
$toastTimer = New-Object Windows.Threading.DispatcherTimer
$toastTimer.Interval = [TimeSpan]::FromSeconds(1)
$toastTimer.Add_Tick({ try { Update-VivacToastWatch } catch { } })
$toastTimer.Start()

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(30)
$timer.Add_Tick({
        if ([VivacKeys]::TakeMenu()) { $queue.Enqueue('menu') }
        if ([VivacKeys]::TakeClipboard()) { $queue.Enqueue('clipboard') }
        if ([VivacKeys]::TakeLock()) { $queue.Enqueue('lock') }
        if ([VivacClipWatch]::TakeChanges()) { try { Add-VivacClipboardEntry } catch { } }
        $steps = [VivacKeys]::TakeVolumeSteps()
        $mutes = [VivacKeys]::TakeMuteToggles()
        if ($steps -or $mutes) {
            try {
                if ($mutes % 2) { [void][VivacAudio]::ToggleMute() }
                if ($steps) { [void][VivacAudio]::Step($steps) }
                Show-VivacVolumeOsd $script:osd ([VivacAudio]::GetVolume()) ([VivacAudio]::GetMute())
            } catch { }
        }
        $verb = $null
        while ($queue.TryDequeue([ref]$verb)) {
            # "Loading..." for a surface on its way (not for one the key is
            # closing): see lib/VivacLoading.cs.
            $coming = $loadingVerbs -contains $verb -and -not ($open[$verb] -and $open[$verb].IsVisible)
            if ($coming) { Start-VivacLoading }
            try { Invoke-Verb $verb } catch { Write-DaemonLog "verb '$verb' failed: $_" }
            if ($coming) { try { [VivacLoading]::Hide() } catch { } }
        }
        if ($script:refreshApps -and -not ($open['menu'] -and $open['menu'].IsVisible)) {
            $script:refreshApps = $false
            try { Update-VivacStartApps } catch { }
        }
    })
if ($LockAtStart) { $queue.Enqueue('greet') }
$timer.Start()
# However the loop ends -- 'quit', or an exception no handler caught -- the
# process ends with it. The pipe's runspace would otherwise keep it alive,
# taking requests and doing nothing, and nothing would start a working one
# (the key guard starts the host only when none is running).
try { [Windows.Threading.Dispatcher]::Run() }
finally {
    try { [VivacKeys]::Uninstall() } catch { }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    try { Clear-VivacLockMarker } catch { }
    # Not $reader.Stop(): the reader sits in WaitForConnection, which a stop
    # cannot interrupt; ending the process ends it.
    [Environment]::Exit(0)
}
