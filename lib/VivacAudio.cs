// Windows' Core Audio, for vivac's sound panel and volume keys: the playback
// and recording devices, which one is the default, their volume and mute, and
// the per-application mixer. Compiled by Add-Type (lib/Surfaces.psm1); C# 5,
// which is what Windows PowerShell 5.1 compiles.
//
// Every interface below is declared method for method in vtable order, as
// COM requires; the ones vivac does not call are kept as placeholders so the
// ones it does land on the right slot. Every method is [PreserveSig]: it\n// returns the HRESULT itself, which the code checks, instead of having the\n// marshaller turn it into an exception and its int into a phantom out value.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class VivacAudioDevice {
    public string Id;
    public string Name;
    public bool IsDefault;
    public int Volume;
    public bool Muted;
}

public class VivacAudioSession {
    public int Index;
    public uint ProcessId;
    public string Name;
    public int Volume;
    public bool Muted;
}

public static class VivacAudio {
    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid fmtid; public int pid; }

    // PROPVARIANT is 24 bytes on x64; only the string member is read.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointer;
    }

    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant pv);

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object endpoint);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator { }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr groupingParam, int flags, out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr groupingParam, int flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid context);
        [PreserveSig] int GetGroupingParam(out Guid param);
        [PreserveSig] int SetGroupingParam(ref Guid param, ref Guid context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleAudioVolume {
        [PreserveSig] int SetMasterVolume(float level, ref Guid context);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    // Undocumented but stable since Windows 7: the only way to change the
    // default device, and what the Sound control panel itself calls.
    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig {
        [PreserveSig] int GetMixFormat();
        [PreserveSig] int GetDeviceFormat();
        [PreserveSig] int ResetDeviceFormat();
        [PreserveSig] int SetDeviceFormat();
        [PreserveSig] int GetProcessingPeriod();
        [PreserveSig] int SetProcessingPeriod();
        [PreserveSig] int GetShareMode();
        [PreserveSig] int SetShareMode();
        [PreserveSig] int GetPropertyValue();
        [PreserveSig] int SetPropertyValue();
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    private class PolicyConfigClient { }

    private const int ClsctxAll = 23;
    private static readonly PropertyKey FriendlyName = new PropertyKey { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };

    private static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)new MMDeviceEnumerator(); }

    private static T Activate<T>(IMMDevice device) {
        Guid iid = typeof(T).GUID;
        object o;
        Marshal.ThrowExceptionForHR(device.Activate(ref iid, ClsctxAll, IntPtr.Zero, out o));
        return (T)o;
    }

    private static IMMDevice Device(string id) {
        IMMDevice d;
        Marshal.ThrowExceptionForHR(Enumerator().GetDevice(id, out d));
        return d;
    }

    private static string NameOf(IMMDevice device) {
        IPropertyStore store;
        if (device.OpenPropertyStore(0, out store) != 0) return "";
        PropertyKey key = FriendlyName;
        PropVariant value;
        if (store.GetValue(ref key, out value) != 0) return "";
        string name = value.vt == 31 ? Marshal.PtrToStringUni(value.pointer) : "";
        PropVariantClear(ref value);
        return name;
    }

    private static string DefaultId(int flow) {
        IMMDevice d;
        if (Enumerator().GetDefaultAudioEndpoint(flow, 1, out d) != 0) return null;
        string id;
        d.GetId(out id);
        return id;
    }

    // flow: 0 playback, 1 recording. Only active devices, as the Sound
    // settings list them.
    public static List<VivacAudioDevice> Devices(int flow) {
        List<VivacAudioDevice> list = new List<VivacAudioDevice>();
        IMMDeviceCollection all;
        Marshal.ThrowExceptionForHR(Enumerator().EnumAudioEndpoints(flow, 1, out all));
        uint count;
        all.GetCount(out count);
        string def = DefaultId(flow);
        for (uint i = 0; i < count; i++) {
            IMMDevice d;
            all.Item(i, out d);
            string id;
            d.GetId(out id);
            IAudioEndpointVolume v = Activate<IAudioEndpointVolume>(d);
            float level; bool mute;
            v.GetMasterVolumeLevelScalar(out level);
            v.GetMute(out mute);
            list.Add(new VivacAudioDevice { Id = id, Name = NameOf(d), IsDefault = id == def, Volume = (int)Math.Round(level * 100), Muted = mute });
        }
        return list;
    }

    public static void SetDefault(string id) {
        IPolicyConfig policy = (IPolicyConfig)new PolicyConfigClient();
        for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(id, role));
    }

    public static void SetVolume(string id, int level) {
        Guid ctx = Guid.Empty;
        Activate<IAudioEndpointVolume>(Device(id)).SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, level)) / 100f, ref ctx);
    }

    public static void SetMute(string id, bool mute) {
        Guid ctx = Guid.Empty;
        Activate<IAudioEndpointVolume>(Device(id)).SetMute(mute, ref ctx);
    }

    // The default playback device, for the volume keys.
    private static IAudioEndpointVolume DefaultEndpoint() {
        IMMDevice d;
        Marshal.ThrowExceptionForHR(Enumerator().GetDefaultAudioEndpoint(0, 1, out d));
        return Activate<IAudioEndpointVolume>(d);
    }
    public static int GetVolume() { float v; DefaultEndpoint().GetMasterVolumeLevelScalar(out v); return (int)Math.Round(v * 100); }
    public static bool GetMute() { bool m; DefaultEndpoint().GetMute(out m); return m; }
    // Steps of two, as Windows' own keys move it; a step up also unmutes.
    public static int Step(int steps) {
        IAudioEndpointVolume ep = DefaultEndpoint();
        float v; ep.GetMasterVolumeLevelScalar(out v);
        int next = Math.Max(0, Math.Min(100, (int)Math.Round(v * 100) + steps * 2));
        Guid ctx = Guid.Empty;
        ep.SetMasterVolumeLevelScalar(next / 100f, ref ctx);
        if (steps > 0) ep.SetMute(false, ref ctx);
        return next;
    }
    public static bool ToggleMute() {
        IAudioEndpointVolume ep = DefaultEndpoint();
        bool m; ep.GetMute(out m);
        Guid ctx = Guid.Empty;
        ep.SetMute(!m, ref ctx);
        return !m;
    }

    // The mixer: the applications playing on the default playback device.
    // A session is addressed by its index at the time of listing; the panel
    // lists again after every change, so an index never outlives its list.
    private static IAudioSessionEnumerator SessionList() {
        IMMDevice d;
        Marshal.ThrowExceptionForHR(Enumerator().GetDefaultAudioEndpoint(0, 1, out d));
        IAudioSessionEnumerator e;
        Marshal.ThrowExceptionForHR(Activate<IAudioSessionManager2>(d).GetSessionEnumerator(out e));
        return e;
    }

    public static List<VivacAudioSession> Sessions(string systemSoundsName) {
        List<VivacAudioSession> list = new List<VivacAudioSession>();
        IAudioSessionEnumerator e = SessionList();
        int count;
        e.GetCount(out count);
        for (int i = 0; i < count; i++) {
            IAudioSessionControl2 s;
            if (e.GetSession(i, out s) != 0) continue;
            int state;
            s.GetState(out state);
            if (state == 2) continue;
            uint pid;
            s.GetProcessId(out pid);
            string name;
            s.GetDisplayName(out name);
            if (s.IsSystemSoundsSession() == 0) {
                name = systemSoundsName;
            } else if (string.IsNullOrEmpty(name) || name.StartsWith("@")) {
                try {
                    Process p = Process.GetProcessById((int)pid);
                    name = !string.IsNullOrEmpty(p.MainWindowTitle) ? p.ProcessName + " - " + p.MainWindowTitle : p.ProcessName;
                } catch { name = "pid " + pid; }
            }
            ISimpleAudioVolume v = (ISimpleAudioVolume)s;
            float level; bool mute;
            v.GetMasterVolume(out level);
            v.GetMute(out mute);
            list.Add(new VivacAudioSession { Index = i, ProcessId = pid, Name = name, Volume = (int)Math.Round(level * 100), Muted = mute });
        }
        return list;
    }

    private static ISimpleAudioVolume Session(int index) {
        IAudioSessionControl2 s;
        Marshal.ThrowExceptionForHR(SessionList().GetSession(index, out s));
        return (ISimpleAudioVolume)s;
    }

    public static void SetSessionVolume(int index, int level) {
        Guid ctx = Guid.Empty;
        Session(index).SetMasterVolume(Math.Max(0, Math.Min(100, level)) / 100f, ref ctx);
    }

    public static void SetSessionMute(int index, bool mute) {
        Guid ctx = Guid.Empty;
        Session(index).SetMute(mute, ref ctx);
    }
}
