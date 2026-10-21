// The keyboard, watched by one low-level hook, for vivac's own keys (the
// Windows key, the volume keys, the lock). Compiled by Add-Type
// (bin/vivac-daemon.ps1, tests/cases/Keys.Tests.ps1); C# 5, which is what
// Windows PowerShell 5.1 compiles. What each key is for is told in the
// daemon, next to where it is installed.
//
// The hook is C# end to end: it runs on every key of the session and must
// never wait on PowerShell. It only counts and flags; the daemon's timer acts.
// Its decisions are in Swallow, which the tests feed key by key with Sent set,
// so the keys it would send are recorded instead of sent.
using System;
using System.Collections.Generic;
using System.Threading;
using System.Runtime.InteropServices;

public static class VivacKeys {
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHookStruct { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)]
    private struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32.dll")] private static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    private static Thread pump = null;
    private static uint pumpId = 0;
    private static readonly HookProc Proc = Callback;
    private static IntPtr hook = IntPtr.Zero;
    private static bool winDown = false;
    private static bool committed = false;
    private static uint winVk = 0x5B;
    private static uint winScan = 0x5B;
    private static int menuPresses = 0;
    private static uint ownedVk = 0;
    private static int clipPresses = 0;
    private static int lockPresses = 0;
    private static int volumeSteps = 0;
    private static int muteToggles = 0;
    public static bool MaskWin = false;
    // While vivac's lock is up: the keys that would get around it go nowhere.
    public static bool LockMode = false;
    private static bool altHeld = false;
    private static bool altGrHeld = false;
    private static bool ctrlHeld = false;
    public static bool TakeVolume = false;
    // Set by the tests: the keys the hook would send are written here as
    // "vk:flags" (hex vk) and not sent.
    public static List<string> Sent = null;
    public static bool WinHeld { get { return winDown; } }

    // The hook lives on a thread of its own that does nothing but pump its
    // messages. On the WPF thread it would stall whenever PowerShell is busy
    // there (building the menu, reading the Start menu's applications), and
    // Windows silently removes a low-level hook that keeps it waiting.
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
    // Back to no key held and nothing counted (the tests, between cases).
    public static void Reset() {
        winDown = false; committed = false; ownedVk = 0; altHeld = false; altGrHeld = false; ctrlHeld = false;
        Array.Clear(held, 0, held.Length);
        LockMode = false; MaskWin = false; TakeVolume = false;
        menuPresses = 0; clipPresses = 0; lockPresses = 0; volumeSteps = 0; muteToggles = 0;
    }
    // The input time (GetTickCount's clock) of the last key the hook was
    // shown, injected or not: what VivacRawKeys is compared with.
    private static int lastSeen = 0;
    public static int LastSeen { get { return Thread.VolatileRead(ref lastSeen); } }
    public static bool TakeMenu() { return Interlocked.Exchange(ref menuPresses, 0) > 0; }
    public static bool TakeClipboard() { return Interlocked.Exchange(ref clipPresses, 0) > 0; }
    public static bool TakeLock() { return Interlocked.Exchange(ref lockPresses, 0) > 0; }
    public static int TakeVolumeSteps() { return Interlocked.Exchange(ref volumeSteps, 0); }
    public static int TakeMuteToggles() { return Interlocked.Exchange(ref muteToggles, 0); }

    private static void Send(uint vk, uint scan, uint flags) {
        if (Sent != null) { Sent.Add(vk.ToString("X2") + ":" + flags); return; }
        keybd_event((byte)vk, (byte)scan, flags, UIntPtr.Zero);
    }

    private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) {
            KbdLlHookStruct k = (KbdLlHookStruct)Marshal.PtrToStructure(lParam, typeof(KbdLlHookStruct));
            Thread.VolatileWrite(ref lastSeen, unchecked((int)k.time));
            if (Swallow(k.vkCode, k.scanCode, k.flags, (int)wParam)) return (IntPtr)1;
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    // What became of each key's press, kept until it is let go: 1 it reached
    // Windows (as itself, or sent on in its place), 2 it was kept from it.
    // A release goes where its press went. The lock comes up and goes away
    // while keys are held, and a release kept from Windows after a press it
    // saw leaves the key down for good: an Alt, a Ctrl or a Win held down
    // across the lock made every key typed into its field a shortcut, and
    // only the space bar seemed to do anything.
    private static readonly byte[] held = new byte[256];
    private static bool relayed = false;

    // True: Windows (and the hooks after this one) never see this key.
    public static bool Swallow(uint vk, uint scan, uint flags, int message) {
        bool injected = (flags & 0x10) != 0;
        if (injected) return false;
        bool down = message == 0x100 || message == 0x104;
        bool up = message == 0x101 || message == 0x105;
        uint i = vk & 0xFF;
        byte was = held[i];
        relayed = false;
        bool kept = Decide(vk, scan, flags, down, up, was);
        if (down && was == 0) held[i] = (byte)(kept && !relayed ? 2 : 1);
        else if (up) held[i] = 0;
        return kept;
    }

    private static bool Decide(uint vk, uint scan, uint flags, bool down, bool up, byte was) {
        // The right Alt is AltGr on most layouts (Spanish among them): it
        // types @ # | \ [ ] { } and the euro sign, so it is not taken for an Alt.
        bool isAltGr = vk == 0xA5;
        bool isAlt = vk == 0x12 || vk == 0xA4;
        bool isCtrl = vk == 0x11 || vk == 0xA2 || vk == 0xA3;
        bool isWin = vk == 0x5B || vk == 0x5C;
        if (isAlt) altHeld = down;
        if (isAltGr) altGrHeld = down;
        if (isCtrl) ctrlHeld = down;
        // The lock screen. Typing reaches it; the Windows key, anything
        // with Alt (Alt+Tab, Alt+F4, Alt+Esc) and Ctrl+Esc (the Start
        // menu, and Ctrl+Shift+Esc, Task Manager) do not. Ctrl+Alt+Del
        // cannot be stopped by anyone, which is why the lock answers it
        // by handing over to Windows' own lock (Show-VivacLock).
        if (LockMode) {
            // A Win held back from before the lock: let go of it the way
            // it would be let go of without the lock.
            if (isWin && up && winDown) {
                bool sent = committed;
                winDown = false; committed = false;
                if (sent) Send(winVk, winScan, 0x1 | 0x2);
                return true;
            }
            if (ownedVk != 0 && vk == ownedVk) {
                if (up) ownedVk = 0;
                return true;
            }
            // A key pressed before the lock: its repeats and its release go
            // where its press went.
            if (was == 1) return false;
            if (was == 2) return true;
            if (up) return false;
            if (isAlt || isWin) return true;
            if (altHeld) return true;
            // AltGr reaches the field, or a password with an @ in it could
            // never be typed there. On a layout without AltGr it is a plain
            // Alt, so what it would switch or close with stays turned away.
            if (altGrHeld && (vk == 0x09 || vk == 0x1B || vk == 0x73 || vk == 0x20)) return true;
            if (ctrlHeld && vk == 0x1B) return true;
            return false;
        }
        // The rest of a combination vivac answers itself (Win+R,
        // Win+V, Win+L): its repeats and its release go nowhere either.
        if (ownedVk != 0 && vk == ownedVk) {
            if (up) ownedVk = 0;
            return true;
        }
        if (TakeVolume && (vk == 0xAD || vk == 0xAE || vk == 0xAF)) {
            if (down) {
                if (vk == 0xAD) Interlocked.Increment(ref muteToggles);
                else if (vk == 0xAF) Interlocked.Increment(ref volumeSteps);
                else Interlocked.Decrement(ref volumeSteps);
            }
            return true;
        }
        // Windows does not see the Win key until it is known what it
        // is for: held back while it is down alone; when another key
        // goes down with it, a Win press and that key are sent in
        // order, which GlazeWM and Windows' own Win shortcuts receive
        // as usual; let go alone, Windows never saw it, so there is
        // nothing to open the Start menu with, and nothing opens.
        // Only Win+R, Win+V and Win+L never reach Windows.
        if (MaskWin && isWin && down) {
            if (!winDown) { winDown = true; committed = false; winVk = vk; winScan = scan; }
            if (!committed) return true;
        } else if (MaskWin && isWin && up && winDown) {
            bool sent = committed;
            winDown = false; committed = false;
            if (sent) Send(winVk, winScan, 0x1 | 0x2);
            return true;
        } else if (down && winDown) {
            // Win+R, Win+V and Win+L are vivac's: its menu, its
            // clipboard history and its lock. Windows never saw the
            // Win key, so it never sees the combination and opens
            // nothing of its own.
            if (MaskWin && !committed && (vk == 0x52 || vk == 0x56 || vk == 0x4C)) {
                ownedVk = vk;
                if (vk == 0x52) Interlocked.Increment(ref menuPresses);
                else if (vk == 0x56) Interlocked.Increment(ref clipPresses);
                else Interlocked.Increment(ref lockPresses);
                return true;
            }
            if (MaskWin && !committed) {
                committed = true;
                relayed = true;
                Send(winVk, winScan, 0x1);
                Send(vk, scan, flags & 0x1);
                return true;
            }
        }
        return false;
    }
}
