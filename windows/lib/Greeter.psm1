# The sign-in greeter's desktop (bin\vivac-greeter.ps1).
#
# Windows keeps one desktop per session for programs ("Default") and switches
# to others of its own for the secure screens (Ctrl+Alt+Del, UAC, its lock).
# The greeter gets a desktop of its own the same way: whatever Windows and
# the Run keys start at sign-in (Explorer, the window manager, the bar, every
# program) opens on Default, unseen and out of reach, while the greeter alone
# is on screen. Unlocking switches back to Default, where everything has had
# the time to load. A desktop has no z-order fights with a topmost bar, no
# keys to swallow and nothing to hide: it is the one thing on screen.
#
# A thread may bind to a desktop (SetThreadDesktop) only before it owns a
# window or a hook. Windows PowerShell's first thread already does by the time
# a script runs (error 170, ERROR_BUSY), so the greeter's windows are built on
# a runspace thread of their own, bound first thing (Bind), and the first
# thread keeps watch from Default.

Set-StrictMode -Version 2.0

$script:GreeterDesktop = 'vivac-greeter'
function Get-VivacGreeterDesktopName { $script:GreeterDesktop }

function Get-VivacDesktopNative {
    if (-not ('VivacDesktopNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class VivacDesktopNative {
    const uint GENERIC_ALL = 0x10000000;
    const uint DESKTOP_READOBJECTS = 0x0001;
    const uint DESKTOP_SWITCHDESKTOP = 0x0100;
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int length, out int needed);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();

    static string NameOf(IntPtr h) {
        if (h == IntPtr.Zero) return null;
        StringBuilder name = new StringBuilder(128); int needed;
        if (!GetUserObjectInformation(h, 2, name, name.Capacity * 2, out needed)) return null;
        return name.ToString();
    }
    // A desktop of this name in the session's window station: made, or
    // opened when it is already there (a greeter that did not clean up).
    public static IntPtr Create(string name) {
        IntPtr h = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
        if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktop " + name);
        return h;
    }
    public static void Close(IntPtr h) { if (h != IntPtr.Zero) CloseDesktop(h); }
    // The calling thread's windows go to this desktop from now on. Only
    // for a thread without windows or hooks yet.
    public static void Bind(IntPtr h) {
        if (!SetThreadDesktop(h)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadDesktop");
    }
    // This desktop on screen and with the keyboard.
    public static void Switch(IntPtr h) {
        if (!SwitchDesktop(h)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SwitchDesktop");
    }
    // The desktop that has the keyboard, by name; null when Windows' own
    // secure screen (Ctrl+Alt+Del, UAC, its lock) has it, which no program
    // may open.
    public static string InputDesktopName() {
        IntPtr d = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
        if (d == IntPtr.Zero) return null;
        try { return NameOf(d); } finally { CloseDesktop(d); }
    }
    public static string ThreadDesktopName() { return NameOf(GetThreadDesktop(GetCurrentThreadId())); }
    // The programs' desktop back on screen. False when it cannot be (the
    // secure screen is up): nothing to do then, Windows comes back by itself.
    public static bool SwitchToDefault() {
        IntPtr d = OpenDesktop("Default", 0, false, DESKTOP_SWITCHDESKTOP);
        if (d == IntPtr.Zero) return false;
        try { return SwitchDesktop(d); } finally { CloseDesktop(d); }
    }
}
'@
    }
    [VivacDesktopNative]
}

# The watchdog's script: a process of its own on the programs' desktop, so
# it outlives the greeter whatever happens to it. When the greeter's process
# is gone it looks at what it left: the screen still on the greeter's desktop
# (brought back to Default), or the greeter's lock marker still there (it did
# not end by unlocking). Either one means the session is not to be left open:
# Windows' own lock. A greeter that unlocked leaves neither, and the watchdog
# just ends. Text, not a script block: it runs in another process.
function Get-VivacGreeterWatchdogScript([int]$GreeterPid, [string]$Desktop, [string]$Marker, [string]$Log) {
    @"
`$ErrorActionPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class VivacGreeterWatch {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int length, out int needed);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();
    public static string InputDesktopName() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001); if (d == IntPtr.Zero) return null;
        try { StringBuilder n = new StringBuilder(128); int k; if (!GetUserObjectInformation(d, 2, n, 256, out k)) return null; return n.ToString(); } finally { CloseDesktop(d); }
    }
    public static bool SwitchToDefault() {
        IntPtr d = OpenDesktop("Default", 0, false, 0x0100); if (d == IntPtr.Zero) return false;
        try { return SwitchDesktop(d); } finally { CloseDesktop(d); }
    }
}
'@
while (Get-Process -Id $GreeterPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 300 }
`$stranded = ([VivacGreeterWatch]::InputDesktopName() -eq '$Desktop')
`$marked = `$false
try { `$marked = (Test-Path -LiteralPath '$Marker') -and ((Get-Content -LiteralPath '$Marker' -Raw) -match '^$GreeterPid ') } catch { }
if (`$stranded) { [void][VivacGreeterWatch]::SwitchToDefault() }
if (`$stranded -or `$marked) {
    if (`$marked) { Remove-Item -LiteralPath '$Marker' -Force -ErrorAction SilentlyContinue }
    [void][VivacGreeterWatch]::LockWorkStation()
    try { Add-Content -LiteralPath '$Log' -Value ('{0}  watchdog: the greeter went without unlocking (stranded={1}, marker={2}): Windows'' own lock' -f (Get-Date -Format s), `$stranded, `$marked) -Encoding UTF8 } catch { }
}
"@
}

# The greeter as a process of its own, started by a host that was asked to
# hold the sign-in (bin\vivac-daemon.ps1 -LockAtStart: how the sign-in task
# of earlier installs starts it). The host then goes on as the host, and the
# greeter has its own desktop, watchdog and grace. Returns the command line;
# -NoStart only says what would run. Throws when the greeter is not there,
# so the host can fall back to holding the sign-in itself.
function Start-VivacSigninGreeter([switch]$NoStart) {
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-greeter.ps1'
    if (-not (Test-Path -LiteralPath $script)) { throw "the greeter is not there: $script" }
    $arguments = @('--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
    if (-not $NoStart) { Start-Process -FilePath 'conhost.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null }
    'conhost.exe ' + ($arguments -join ' ')
}

Export-ModuleMember -Function Get-VivacGreeterDesktopName, Get-VivacDesktopNative, Get-VivacGreeterWatchdogScript, Start-VivacSigninGreeter
