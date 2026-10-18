<#
.SYNOPSIS
  Keeps the Windows key vivac's where the resident host cannot see it.

.DESCRIPTION
  bin/vivac-daemon.ps1 holds back the Windows key (Win alone opens nothing,
  Win+R is vivac's menu, Win+V its clipboard history, Win+L its lock) with a
  low-level keyboard hook. That host runs at the normal integrity level, on
  purpose: what it starts must not start as administrator. But Windows does
  not show a normal process the keys typed into an elevated window, so with
  an administrator's terminal in front the Start menu and the Run box came
  back.

  This process runs elevated (the sign-in task \vivac\keyguard starts it)
  and does nothing but that same holding back, and only when the host is
  blind: the window in front belongs to an elevated or protected process,
  or the host is not running at all. Otherwise it passes every key on and
  the host answers as before. Win+R, Win+V and Win+L become the host's
  verbs, written to its pipe as the bar's buttons write theme or power. Ctrl+Esc,
  the other way to the Start menu, never reaches Windows (Ctrl+Shift+Esc,
  Task Manager, still does).

  When the host is not running, this restarts it through the task
  \vivac\daemon, which runs it at the normal level as GlazeWM does.

  The hook is put back every half minute: Windows drops a low-level hook
  without a word if it is ever slow to answer, and nothing would notice.

  It also keeps two promises the hidden taskbar would otherwise break: the
  bar's strip belongs to the bar (VivacBarGuard below), and a program asking
  for administrator rights from the background gets its UAC prompt shown,
  where Windows would only flash a taskbar button nobody can see.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force

$created = $false
$script:GuardMutex = New-Object System.Threading.Mutex($true, 'Local\vivac-keyguard', [ref]$created)
if (-not $created) { exit 0 }

# Elevated, the guard writes only where the user cannot (a folder the user
# controls could be turned into a link that sends the write elsewhere).
$log = Join-Path $env:ProgramData 'vivac\logs\keyguard.log'
if (-not (Test-Path -LiteralPath (Split-Path -Parent $log))) { $log = Join-Path (Get-VivacPaths).State 'keyguard.log' }
function Write-GuardLog([string]$Text) {
    try { Add-Content -LiteralPath $log -Value ('{0}  {1}' -f (Get-Date -Format s), $Text) } catch { }
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class VivacGuard {
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHookStruct { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] private static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int ret);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint n);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    private static readonly HookProc Proc = Callback;
    private static Thread pump = null;
    private static uint pumpId = 0;
    private static IntPtr hook = IntPtr.Zero;
    public static string PipePath = "";
    public static volatile bool HostAlive = true;
    public static int Verbs = 0;
    private static bool winDown = false;
    private static bool guarding = false;
    private static bool committed = false;
    private static uint winVk = 0x5B, winScan = 0x5B, ownedVk = 0;

    public static bool Install() {
        if (pump != null) return hook != IntPtr.Zero;
        ManualResetEvent ready = new ManualResetEvent(false);
        pump = new Thread(() => {
            pumpId = GetCurrentThreadId();
            hook = SetWindowsHookEx(13, Proc, GetModuleHandle(null), 0);
            ready.Set();
            Msg m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        });
        pump.IsBackground = true;
        pump.Start();
        ready.WaitOne();
        return hook != IntPtr.Zero;
    }
    public static void Uninstall() {
        if (pump == null) return;
        PostThreadMessage(pumpId, 0x12, IntPtr.Zero, IntPtr.Zero);
        pump.Join(2000);
        pump = null;
    }
    // Not while the key is held: a hook put back mid-combination would lose
    // the state of it.
    public static bool Reinstall() {
        if (winDown) return hook != IntPtr.Zero;
        Uninstall();
        return Install();
    }

    // The host cannot see this window's keys: it belongs to a process above
    // the normal integrity level, or to one this cannot even open (a
    // protected one), which the host cannot read either.
    private static bool ForegroundIsAbove() {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        if (pid == 0) return false;
        IntPtr p = OpenProcess(0x1000, false, pid);
        if (p == IntPtr.Zero) return true;
        try {
            IntPtr t;
            if (!OpenProcessToken(p, 0x8, out t)) return true;
            try {
                int len;
                GetTokenInformation(t, 25, IntPtr.Zero, 0, out len);
                IntPtr buf = Marshal.AllocHGlobal(len);
                try {
                    if (!GetTokenInformation(t, 25, buf, len, out len)) return true;
                    IntPtr sid = Marshal.ReadIntPtr(buf);
                    int n = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(n - 1))) > 0x2000;
                } finally { Marshal.FreeHGlobal(buf); }
            } finally { CloseHandle(t); }
        } finally { CloseHandle(p); }
    }

    // Written off the hook's thread: the hook must never wait.
    private static void Send(string verb) {
        Interlocked.Increment(ref Verbs);
        ThreadPool.QueueUserWorkItem(_ => {
            try {
                using (NamedPipeClientStream c = new NamedPipeClientStream(".", PipePath, PipeDirection.Out)) {
                    c.Connect(1500);
                    byte[] b = Encoding.ASCII.GetBytes(verb + "\n");
                    c.Write(b, 0, b.Length);
                }
            } catch { }
        });
    }

    private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            KbdLlHookStruct k = (KbdLlHookStruct)Marshal.PtrToStructure(lParam, typeof(KbdLlHookStruct));
            bool injected = (k.flags & 0x10) != 0;
            bool down = wParam == (IntPtr)0x100 || wParam == (IntPtr)0x104;
            bool up = wParam == (IntPtr)0x101 || wParam == (IntPtr)0x105;
            if (!injected) {
                // Ctrl+Esc opens the Start menu too; with Shift it is Task
                // Manager, which stays.
                if (k.vkCode == 0x1B && down && GetAsyncKeyState(0x11) < 0 && GetAsyncKeyState(0x10) >= 0) return (IntPtr)1;
                if (ownedVk != 0 && k.vkCode == ownedVk) {
                    if (up) ownedVk = 0;
                    return (IntPtr)1;
                }
                bool isWin = k.vkCode == 0x5B || k.vkCode == 0x5C;
                if (isWin && down && !winDown) {
                    // Decided once per press, at the press: the host answers
                    // this one, or this process does, to the end of it.
                    guarding = !HostAlive || ForegroundIsAbove();
                    winDown = true; committed = false; winVk = k.vkCode; winScan = k.scanCode;
                }
                if (winDown && guarding) {
                    if (isWin && down) {
                        if (!committed) return (IntPtr)1;
                    } else if (isWin && up) {
                        bool sent = committed;
                        winDown = false; committed = false; guarding = false;
                        if (sent) keybd_event((byte)winVk, (byte)winScan, 0x1 | 0x2, UIntPtr.Zero);
                        return (IntPtr)1;
                    } else if (down && !committed) {
                        if (k.vkCode == 0x52 || k.vkCode == 0x56 || k.vkCode == 0x4C) {
                            ownedVk = k.vkCode;
                            Send(k.vkCode == 0x52 ? "menu" : k.vkCode == 0x56 ? "clipboard" : "lock");
                            return (IntPtr)1;
                        }
                        committed = true;
                        keybd_event((byte)winVk, (byte)winScan, 0x1, UIntPtr.Zero);
                        keybd_event((byte)k.vkCode, (byte)k.scanCode, (k.flags & 0x1), UIntPtr.Zero);
                        return (IntPtr)1;
                    }
                } else if (isWin && up && winDown) {
                    winDown = false; guarding = false;
                }
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }
}
'@

# The bar's strip at the top of the screen belongs to the bar, whatever any
# program does (the user's rule, with no exceptions). GlazeWM keeps the windows
# it tiles below it, and a maximized or fullscreen one fills the work area;
# this watches for everything else, as Windows reports it:
#
# - Anything that ends up in front of the bar (another always-on-top window, a
#   borderless fullscreen one) sends the bar back in front at once. Small
#   things (menus, tooltips) do not count; they are gone in a moment.
# - A window with a title bar that puts itself into the strip (one GlazeWM
#   leaves alone, floating or ignored, or one that moves itself) is moved down
#   to just below it, and made shorter if it would then run off the screen.
#
# Left alone: vivac's own windows (titled "vivac..."; the lock must cover the
# bar), Zebar's (the bar and its popups), the Snipping Tool's capture overlay
# and toolbar (a capture must be able to include the bar), the desktop, and
# windows Windows has cloaked (those on other workspaces, suspended apps).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class VivacBarGuard {
    private delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] private static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetTopWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect r);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out Rect r, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int v, int size);

    private static readonly WinEventProc Proc = OnEvent;
    private static volatile bool dirty = true;
    private static IntPtr bar = IntPtr.Zero;
    private static Timer timer;
    private static int ticks = 0;
    public static int Raised = 0, Moved = 0;
    private static readonly Dictionary<IntPtr, int> nudges = new Dictionary<IntPtr, int>();
    private static readonly Dictionary<uint, string> names = new Dictionary<uint, string>();
    private static readonly string[] skipProcesses = { "zebar", "ScreenClippingHost", "SnippingTool" };
    private static readonly string[] skipClasses = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd" };

    public static void Start() {
        Thread t = new Thread(() => {
            // Shown, moved or resized, brought to the front, re-ordered.
            SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, Proc, 0, 0, 0x2);
            SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, Proc, 0, 0, 0x2);
            SetWinEventHook(0x8004, 0x8004, IntPtr.Zero, Proc, 0, 0, 0x2);
            SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, Proc, 0, 0, 0x2);
            Msg m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        });
        t.IsBackground = true;
        t.Start();
        // Acted on in batches, at most ten times a second, and every second
        // whatever happened, in case an event never came.
        timer = new Timer(_ => {
            if (++ticks % 10 == 0) {
                dirty = true;
                lock (nudges) nudges.Clear();
                try { ShowWaitingConsent(); } catch { }
            }
            if (!dirty) return;
            dirty = false;
            try { Enforce(); } catch { }
        }, null, 100, 100);
    }

    // A program that asks to run as administrator while it is not in front
    // gets no prompt: Windows puts a flashing taskbar button in its place
    // (consent.exe's "interim" window) and waits for it to be clicked. vivac
    // hides the taskbar, so the prompt waited forever, unseen. Each such
    // window is brought forward here, which is what the click does, and the
    // prompt appears; again every few seconds while it is still waiting.
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    private static readonly Dictionary<IntPtr, DateTime> consentShown = new Dictionary<IntPtr, DateTime>();
    public static int ConsentShown = 0;
    private static void ShowWaitingConsent() {
        List<IntPtr> waiting = new List<IntPtr>();
        EnumWindows((h, d) => {
            StringBuilder c = new StringBuilder(256);
            GetClassName(h, c, 256);
            if (c.ToString().StartsWith("$$$Secure UAP Dummy Window Class")) waiting.Add(h);
            return true;
        }, IntPtr.Zero);
        foreach (IntPtr h in waiting) {
            DateTime last;
            if (consentShown.TryGetValue(h, out last) && (DateTime.UtcNow - last).TotalSeconds < 8) continue;
            consentShown[h] = DateTime.UtcNow;
            // What clicking its taskbar button does: restore it. Only the
            // message works; ShowWindow, OpenIcon and SetForegroundWindow on
            // it change nothing (consent.exe runs as SYSTEM).
            PostMessage(h, 0x0112, new IntPtr(0xF120), IntPtr.Zero);
            ConsentShown++;
        }
        if (consentShown.Count > 50) consentShown.Clear();
    }

    private static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time) {
        if (obj == 0 && child == 0) dirty = true;
    }

    private static string ProcessName(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        string n;
        lock (names) {
            if (names.TryGetValue(pid, out n)) return n;
            try { n = Process.GetProcessById((int)pid).ProcessName; } catch { n = ""; }
            if (names.Count > 500) names.Clear();
            names[pid] = n;
        }
        return n;
    }

    private static bool Exempt(IntPtr hwnd) {
        int cloaked;
        if (DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
        StringBuilder s = new StringBuilder(256);
        GetWindowText(hwnd, s, 256);
        if (s.ToString().StartsWith("vivac", StringComparison.OrdinalIgnoreCase)) return true;
        s.Clear();
        GetClassName(hwnd, s, 256);
        if (Array.IndexOf(skipClasses, s.ToString()) >= 0) return true;
        return Array.IndexOf(skipProcesses, ProcessName(hwnd)) >= 0;
    }

    // What the window shows on screen, without the invisible resize borders.
    private static Rect Visible(IntPtr hwnd) {
        Rect r;
        if (DwmGetWindowAttribute(hwnd, 9, out r, 16) != 0) GetWindowRect(hwnd, out r);
        return r;
    }

    private static bool Overlaps(Rect a, Rect b) { return a.L < b.R && b.L < a.R && a.T < b.B && b.T < a.B; }

    private static void Enforce() {
        if (bar == IntPtr.Zero || !IsWindow(bar)) bar = FindWindow("Tauri Window", "Zebar - vivac / bar");
        if (bar == IntPtr.Zero || !IsWindowVisible(bar)) return;
        Rect strip;
        GetWindowRect(bar, out strip);
        MonitorInfo mi = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
        GetMonitorInfo(MonitorFromWindow(bar, 2), ref mi);
        // The work area's top is where the bar's reservation ends; while it
        // is missing (Explorer restarting), the bar's own bottom edge.
        int below = mi.Work.T > mi.Monitor.T ? mi.Work.T : strip.B;
        int width = mi.Monitor.R - mi.Monitor.L;

        // In front of the bar: every window above it in the z-order.
        for (IntPtr h = GetTopWindow(IntPtr.Zero); h != IntPtr.Zero && h != bar; h = GetWindow(h, 2)) {
            if (!IsWindowVisible(h) || IsIconic(h) || Exempt(h)) continue;
            Rect r = Visible(h);
            if (!Overlaps(r, strip)) continue;
            bool titled = (GetWindowLong(h, -16) & 0x00C00000) == 0x00C00000;
            if (!titled && (r.R - r.L) < width * 3 / 10) continue;
            SetWindowPos(bar, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x200);
            Raised++;
            break;
        }

        // In the strip, behind the bar: titled windows only.
        List<IntPtr> intruders = new List<IntPtr>();
        EnumWindows((h, d) => {
            if (h == bar || !IsWindowVisible(h) || IsIconic(h)) return true;
            int style = GetWindowLong(h, -16);
            if ((style & 0x00C00000) != 0x00C00000 || (style & 0x40000000) != 0) return true;
            Rect r = Visible(h);
            if (r.T < below && r.B > mi.Monitor.T && r.L < mi.Monitor.R && r.R > mi.Monitor.L && !Exempt(h)) intruders.Add(h);
            return true;
        }, IntPtr.Zero);
        foreach (IntPtr h in intruders) {
            // A window that puts itself straight back is let be for a while,
            // rather than fought over many times a second.
            lock (nudges) {
                int n;
                nudges.TryGetValue(h, out n);
                if (n >= 3) continue;
                nudges[h] = n + 1;
            }
            Rect vis = Visible(h);
            Rect win;
            GetWindowRect(h, out win);
            int down = below - vis.T;
            int top = win.T + down;
            int height = win.B - win.T;
            int overrun = (vis.B + down) - mi.Work.B;
            if (overrun > 0) height -= overrun;
            SetWindowPos(h, IntPtr.Zero, win.L, top, win.R - win.L, Math.Max(height, 100), 0x4 | 0x10 | 0x200);
            Moved++;
        }
    }
}
'@
[VivacBarGuard]::Start()

$settings = Read-VivacSettings
# The Windows key is only vivac's with Win as the modifier; the bar's strip is
# guarded either way.
$guardKeys = $settings['mod'] -eq 'lwin'
[VivacGuard]::PipePath = Get-VivacPipeName
if ($guardKeys -and -not [VivacGuard]::Install()) { Write-GuardLog 'the keyboard hook could not be installed'; $guardKeys = $false }
Write-GuardLog "started, pid $PID (keys: $guardKeys, bar strip: yes)"

# Every 3 s: is the host there? If not for two looks running, start it again.
# Every 30 s: the hook put back.
$missing = 0
$tick = 0
while ($true) {
    Start-Sleep -Seconds 3
    $tick++
    $alive = $false
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting('Local\vivac-daemon', [ref]$m)) { $alive = $true; $m.Dispose() }
    [VivacGuard]::HostAlive = $alive
    if ($alive) { $missing = 0 }
    else {
        $missing++
        if ($missing -eq 2) {
            Write-GuardLog 'host not running: starting \vivac\daemon'
            try { Start-ScheduledTask -TaskPath '\vivac\' -TaskName 'daemon' } catch { Write-GuardLog "could not start it: $($_.Exception.Message)" }
        }
        if ($missing -ge 20) { $missing = 0 }
    }
    if ($guardKeys -and $tick % 10 -eq 0) {
        if (-not [VivacGuard]::Reinstall()) { Write-GuardLog 'the hook could not be put back' }
    }
    # What the bar watch did, now and then, for the log.
    if ($tick % 200 -eq 0 -and ([VivacBarGuard]::Raised -or [VivacBarGuard]::Moved -or [VivacBarGuard]::ConsentShown)) {
        Write-GuardLog "bar strip: bar raised $([VivacBarGuard]::Raised) times, windows moved down $([VivacBarGuard]::Moved) times; waiting UAC prompts brought up $([VivacBarGuard]::ConsentShown) times"
    }
}
