// Windows' classic Bluetooth API (bthprops), for vivac's Bluetooth panel:
// the devices Windows remembers and whether each is connected, a search for
// the ones in range, pairing, forgetting, and connecting or disconnecting.
// Compiled by Add-Type (lib/Bluetooth.psm1); C# 5, which is what Windows
// PowerShell 5.1 compiles.
//
// There is no "connect" call in this API: a device connects when one of its
// services is enabled and drops when they are all disabled, which is what the
// Settings page does too. A device Windows has no installed service for yet
// is offered the usual ones for its class (audio, input).
//
// Bluetooth LE devices do not show here: the classic API only sees classic
// ones, and those are what headphones, speakers and most keyboards pair as.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public class VivacBtDevice {
    public string Name;
    public ulong Address;
    public uint ClassOfDevice;
    public bool Connected;
    public bool Paired;
    // 'audio', 'input', 'phone', 'computer' or 'other', from the class of device.
    public string Kind;
    // Finer, for the glyph: 'headphones', 'headset', 'speaker', 'car',
    // 'keyboard', 'mouse', 'gamepad', 'phone', 'computer', 'watch' or 'other'.
    public string Type;
}

public static class VivacBluetooth {
    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEMTIME { public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct BLUETOOTH_DEVICE_INFO {
        public int dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        public bool fConnected;
        public bool fRemembered;
        public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)] public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BLUETOOTH_DEVICE_SEARCH_PARAMS {
        public int dwSize;
        public bool fReturnAuthenticated;
        public bool fReturnRemembered;
        public bool fReturnUnknown;
        public bool fReturnConnected;
        public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BLUETOOTH_FIND_RADIO_PARAMS { public int dwSize; }

    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern IntPtr BluetoothFindFirstRadio(ref BLUETOOTH_FIND_RADIO_PARAMS p, out IntPtr hRadio);
    [DllImport("bthprops.cpl")]
    static extern bool BluetoothFindRadioClose(IntPtr hFind);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS p, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl", SetLastError = true)]
    static extern bool BluetoothFindNextDevice(IntPtr hFind, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl")]
    static extern bool BluetoothFindDeviceClose(IntPtr hFind);
    [DllImport("bthprops.cpl")]
    static extern int BluetoothGetDeviceInfo(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info);
    [DllImport("bthprops.cpl")]
    static extern int BluetoothRemoveDevice(ref ulong address);
    [DllImport("bthprops.cpl")]
    static extern int BluetoothEnumerateInstalledServices(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info, ref int count, [Out] Guid[] services);
    [DllImport("bthprops.cpl")]
    static extern int BluetoothSetServiceState(IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info, ref Guid service, int flags);
    [DllImport("bthprops.cpl")]
    static extern int BluetoothAuthenticateDeviceEx(IntPtr hwnd, IntPtr hRadio, ref BLUETOOTH_DEVICE_INFO info, IntPtr oobData, int authRequirements);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    const int SERVICE_DISABLE = 0, SERVICE_ENABLE = 1;
    const int MITMProtectionNotRequiredGeneralBonding = 0x04;

    // Audio sink, headset and hands-free, the remote control that comes with
    // them, and HID: what a device of each class connects through.
    static readonly Guid[] AudioServices = {
        new Guid("0000110b-0000-1000-8000-00805f9b34fb"), new Guid("00001108-0000-1000-8000-00805f9b34fb"),
        new Guid("0000111e-0000-1000-8000-00805f9b34fb"), new Guid("0000110e-0000-1000-8000-00805f9b34fb"),
    };
    static readonly Guid[] InputServices = { new Guid("00001124-0000-1000-8000-00805f9b34fb") };

    static IntPtr OpenRadio() {
        var p = new BLUETOOTH_FIND_RADIO_PARAMS { dwSize = Marshal.SizeOf(typeof(BLUETOOTH_FIND_RADIO_PARAMS)) };
        IntPtr radio;
        IntPtr find = BluetoothFindFirstRadio(ref p, out radio);
        if (find == IntPtr.Zero) return IntPtr.Zero;
        BluetoothFindRadioClose(find);
        return radio;
    }

    public static bool HasRadio() {
        IntPtr r = OpenRadio();
        if (r == IntPtr.Zero) return false;
        CloseHandle(r);
        return true;
    }

    static string KindOf(uint cod) {
        switch ((cod >> 8) & 0x1F) {
            case 1: return "computer";
            case 2: return "phone";
            case 4: return "audio";
            case 5: return "input";
            default: return "other";
        }
    }

    // The major class, then the minor one within it (Bluetooth Assigned
    // Numbers, "Class of Device").
    public static string TypeOf(uint cod) {
        uint major = (cod >> 8) & 0x1F, minor = (cod >> 2) & 0x3F;
        switch (major) {
            case 1: return "computer";
            case 2: return "phone";
            case 4:
                if (minor == 1 || minor == 2) return "headset";
                if (minor == 5 || minor == 7 || minor == 10) return "speaker";
                if (minor == 8) return "car";
                return "headphones";
            case 5:
                if ((minor & 0xF) == 1 || (minor & 0xF) == 2) return "gamepad";
                if ((minor >> 4) == 2) return "mouse";
                return "keyboard";
            case 7: return "watch";
            default: return "other";
        }
    }

    static BLUETOOTH_DEVICE_INFO NewInfo(ulong address) {
        return new BLUETOOTH_DEVICE_INFO { dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO)), Address = address };
    }

    // The remembered devices, at once; with inquiry, also the ones in range,
    // which takes about 1.28 s per step of the multiplier.
    public static List<VivacBtDevice> Devices(bool inquiry, byte timeoutMultiplier) {
        var list = new List<VivacBtDevice>();
        IntPtr radio = OpenRadio();
        if (radio == IntPtr.Zero) return list;
        try {
            var p = new BLUETOOTH_DEVICE_SEARCH_PARAMS {
                dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_SEARCH_PARAMS)),
                fReturnAuthenticated = true, fReturnRemembered = true, fReturnConnected = true,
                fReturnUnknown = inquiry, fIssueInquiry = inquiry, cTimeoutMultiplier = timeoutMultiplier, hRadio = radio,
            };
            var info = NewInfo(0);
            IntPtr find = BluetoothFindFirstDevice(ref p, ref info);
            if (find == IntPtr.Zero) return list;
            var seen = new HashSet<ulong>();
            do {
                if (seen.Add(info.Address)) {
                    list.Add(new VivacBtDevice {
                        Name = string.IsNullOrEmpty(info.szName) ? FormatAddress(info.Address) : info.szName,
                        Address = info.Address, ClassOfDevice = info.ulClassofDevice,
                        Connected = info.fConnected, Paired = info.fAuthenticated || info.fRemembered,
                        Kind = KindOf(info.ulClassofDevice), Type = TypeOf(info.ulClassofDevice),
                    });
                }
                info = NewInfo(0);
            } while (BluetoothFindNextDevice(find, ref info));
            BluetoothFindDeviceClose(find);
        } finally { CloseHandle(radio); }
        return list;
    }

    // The search runs off the window's thread; the panel polls the task.
    public static Task<List<VivacBtDevice>> Scan(byte timeoutMultiplier) {
        return Task.Run(() => Devices(true, timeoutMultiplier));
    }

    public static string FormatAddress(ulong a) {
        var b = BitConverter.GetBytes(a);
        return string.Format("{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}", b[5], b[4], b[3], b[2], b[1], b[0]);
    }

    // Pairs with Windows' own prompt when the device asks for a code; the
    // hwnd is the panel, so the prompt sits over it. 0 is success.
    public static int Pair(ulong address, IntPtr hwnd) {
        IntPtr radio = OpenRadio();
        if (radio == IntPtr.Zero) return -1;
        try {
            var info = NewInfo(address);
            BluetoothGetDeviceInfo(radio, ref info);
            int rc = BluetoothAuthenticateDeviceEx(hwnd, radio, ref info, IntPtr.Zero, MITMProtectionNotRequiredGeneralBonding);
            if (rc == 0) SetServices(radio, ref info, SERVICE_ENABLE);
            return rc;
        } finally { CloseHandle(radio); }
    }

    public static int Forget(ulong address) { return BluetoothRemoveDevice(ref address); }

    // Pairing waits on the device and on whoever types its code, and a
    // service change on the driver: both run off the window's thread.
    public static Task<int> PairAsync(ulong address, IntPtr hwnd) { return Task.Run(() => Pair(address, hwnd)); }
    public static Task<int> SetConnectedAsync(ulong address, bool connect) { return Task.Run(() => SetConnected(address, connect)); }

    public static int SetConnected(ulong address, bool connect) {
        IntPtr radio = OpenRadio();
        if (radio == IntPtr.Zero) return -1;
        try {
            var info = NewInfo(address);
            int rc = BluetoothGetDeviceInfo(radio, ref info);
            if (rc != 0) return rc;
            return SetServices(radio, ref info, connect ? SERVICE_ENABLE : SERVICE_DISABLE);
        } finally { CloseHandle(radio); }
    }

    // Only the services of the device's class are touched, both ways: a
    // disabled service is no longer "installed", so connecting again has to
    // name it, and naming it from the class means nothing is turned off that
    // this cannot turn back on.
    public static bool CanConnect(string kind) { return kind == "audio" || kind == "input"; }

    static int SetServices(IntPtr radio, ref BLUETOOTH_DEVICE_INFO info, int flag) {
        string kind = KindOf(info.ulClassofDevice);
        Guid[] services = kind == "audio" ? AudioServices : kind == "input" ? InputServices : new Guid[0];
        int result = -1;
        foreach (var g in services) {
            Guid s = g;
            int rc = BluetoothSetServiceState(radio, ref info, ref s, flag);
            // A service the device does not offer is refused; one that took is enough.
            if (rc == 0) result = 0; else if (result != 0) result = rc;
        }
        return result;
    }
}
