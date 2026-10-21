// The network panel's data (lib/Network.psm1, Show-Network).
//
// Wi-Fi through the Native Wifi API (wlanapi.dll), which answers in numbers
// and the same in every language, where netsh answers in the user's (and in
// the console's code page). The wired side through .NET's NetworkInformation.
// Everything here may run on a worker thread: nothing touches a window.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

public class VivacWifiNetwork {
    public string Ssid;
    public string Profile = "";
    public int Signal;
    public bool Secured;
    public bool Known;
    public bool Connected;
    public bool Connectable;
    // DOT11_AUTH_ALGORITHM: 1 open, 2 shared key, 3/4 WPA, 6/7 WPA2, 8/9 WPA3, 10 OWE.
    public int Auth;
    public int Cipher;
}

public class VivacAdapter {
    public string Id = "";
    public string Name = "";
    public string Description = "";
    public bool Up;
    public bool Wifi;
    public long SpeedMbps;
    public string Mac = "";
    public bool Dhcp;
    public string[] Ipv4 = new string[0];
    public string[] Ipv6 = new string[0];
    public string[] Gateways = new string[0];
    public string[] Dns = new string[0];
}

public class VivacWifiState {
    public bool HasInterface;
    public Guid Interface;
    public string InterfaceName = "";
    public bool RadioOn;
    public bool HardwareOff;
    public bool Connected;
    public string Ssid = "";
    public string Profile = "";
    public int Signal;
    public int Rssi;
    public int RxMbps;
    public int TxMbps;
    public int FreqMHz;
    public string Band = "";
    public int Channel;
    public int Auth;
    public List<VivacWifiNetwork> Networks = new List<VivacWifiNetwork>();
    public List<VivacAdapter> Adapters = new List<VivacAdapter>();
    public string Error = "";
}

public static class VivacNetwork {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionParameters {
        public int Mode;
        [MarshalAs(UnmanagedType.LPWStr)] public string Profile;
        public IntPtr Ssid;
        public IntPtr BssidList;
        public int BssType;
        public uint Flags;
    }
    [DllImport("wlanapi.dll")] private static extern int WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")] private static extern int WlanCloseHandle(IntPtr handle, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern void WlanFreeMemory(IntPtr memory);
    [DllImport("wlanapi.dll")] private static extern int WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern int WlanGetAvailableNetworkList(IntPtr handle, ref Guid iface, uint flags, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern int WlanQueryInterface(IntPtr handle, ref Guid iface, int opcode, IntPtr reserved, out uint size, out IntPtr data, out int valueType);
    [DllImport("wlanapi.dll")] private static extern int WlanGetNetworkBssList(IntPtr handle, ref Guid iface, IntPtr ssid, int bssType, bool securityEnabled, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern int WlanScan(IntPtr handle, ref Guid iface, IntPtr ssid, IntPtr ie, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern int WlanConnect(IntPtr handle, ref Guid iface, ref ConnectionParameters parameters, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern int WlanDisconnect(IntPtr handle, ref Guid iface, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern int WlanDeleteProfile(IntPtr handle, ref Guid iface, string name, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern int WlanSetProfile(IntPtr handle, ref Guid iface, uint flags, string xml, string security, bool overwrite, IntPtr reserved, out uint reason);

    private static IntPtr Open() {
        uint v; IntPtr h;
        int rc = WlanOpenHandle(2, IntPtr.Zero, out v, out h);
        if (rc != 0) throw new InvalidOperationException("WlanOpenHandle " + rc);
        return h;
    }

    private static string ReadSsid(IntPtr p) {
        int len = Marshal.ReadInt32(p);
        if (len <= 0 || len > 32) return "";
        byte[] b = new byte[len];
        Marshal.Copy(IntPtr.Add(p, 4), b, 0, len);
        return Encoding.UTF8.GetString(b);
    }

    // The first Wi-Fi interface: there is one on nearly every machine.
    private static bool FirstInterface(IntPtr h, out Guid id, out string name) {
        id = Guid.Empty; name = "";
        IntPtr list;
        if (WlanEnumInterfaces(h, IntPtr.Zero, out list) != 0) return false;
        try {
            int n = Marshal.ReadInt32(list);
            if (n < 1) return false;
            IntPtr item = IntPtr.Add(list, 8);
            byte[] g = new byte[16];
            Marshal.Copy(item, g, 0, 16);
            id = new Guid(g);
            name = Marshal.PtrToStringUni(IntPtr.Add(item, 16));
            return true;
        } finally { WlanFreeMemory(list); }
    }

    public static int ChannelOf(int mhz) {
        if (mhz == 2484) return 14;
        if (mhz >= 2412 && mhz < 2484) return (mhz - 2407) / 5;
        if (mhz >= 5955) return (mhz - 5950) / 5;
        if (mhz >= 5000) return (mhz - 5000) / 5;
        return 0;
    }
    public static string BandOf(int mhz) {
        if (mhz <= 0) return "";
        if (mhz < 3000) return "2,4 GHz";
        if (mhz >= 5925) return "6 GHz";
        return "5 GHz";
    }

    public static VivacWifiState GetState() {
        VivacWifiState s = new VivacWifiState();
        try { ReadWifi(s); } catch (Exception e) { s.Error = e.Message; }
        try { s.Adapters = GetAdapters(); } catch (Exception e) { s.Error += " " + e.Message; }
        return s;
    }

    private static void ReadWifi(VivacWifiState s) {
        IntPtr h;
        try { h = Open(); } catch { return; }
        try {
            Guid id; string name;
            if (!FirstInterface(h, out id, out name)) return;
            s.HasInterface = true; s.Interface = id; s.InterfaceName = name;

            uint size; IntPtr data; int vt;
            // wlan_intf_opcode_radio_state: per phy, software and hardware state (1 on, 2 off).
            if (WlanQueryInterface(h, ref id, 4, IntPtr.Zero, out size, out data, out vt) == 0) {
                try {
                    int phys = Marshal.ReadInt32(data);
                    bool soft = phys == 0, hard = phys == 0;
                    for (int i = 0; i < phys; i++) {
                        IntPtr e = IntPtr.Add(data, 4 + i * 12);
                        if (Marshal.ReadInt32(e, 4) == 1) soft = true;
                        if (Marshal.ReadInt32(e, 8) == 1) hard = true;
                    }
                    s.RadioOn = soft && hard;
                    s.HardwareOff = !hard;
                } finally { WlanFreeMemory(data); }
            } else { s.RadioOn = true; }

            // wlan_intf_opcode_current_connection: WLAN_CONNECTION_ATTRIBUTES.
            byte[] bssid = null;
            if (WlanQueryInterface(h, ref id, 7, IntPtr.Zero, out size, out data, out vt) == 0) {
                try {
                    // wlan_interface_state_connected
                    if (Marshal.ReadInt32(data, 0) == 1) {
                        s.Connected = true;
                        s.Profile = Marshal.PtrToStringUni(IntPtr.Add(data, 8));
                        s.Ssid = ReadSsid(IntPtr.Add(data, 520));
                        bssid = new byte[6];
                        Marshal.Copy(IntPtr.Add(data, 560), bssid, 0, 6);
                        s.Signal = Marshal.ReadInt32(data, 576);
                        s.RxMbps = Marshal.ReadInt32(data, 580) / 1000;
                        s.TxMbps = Marshal.ReadInt32(data, 584) / 1000;
                        // WLAN_SECURITY_ATTRIBUTES follow at 588: enabled, 802.1X, auth, cipher.
                        s.Auth = Marshal.ReadInt32(data, 596);
                    }
                } finally { WlanFreeMemory(data); }
            }

            IntPtr nets;
            if (WlanGetAvailableNetworkList(h, ref id, 0, IntPtr.Zero, out nets) == 0) {
                try {
                    int n = Marshal.ReadInt32(nets);
                    Dictionary<string, VivacWifiNetwork> bySsid = new Dictionary<string, VivacWifiNetwork>();
                    for (int i = 0; i < n; i++) {
                        IntPtr e = IntPtr.Add(nets, 8 + i * 628);
                        string ssid = ReadSsid(IntPtr.Add(e, 512));
                        if (ssid.Length == 0) continue;
                        // Infrastructure networks only.
                        if (Marshal.ReadInt32(e, 548) != 1) continue;
                        uint flags = (uint)Marshal.ReadInt32(e, 620);
                        VivacWifiNetwork w;
                        if (!bySsid.TryGetValue(ssid, out w)) { w = new VivacWifiNetwork(); w.Ssid = ssid; bySsid[ssid] = w; }
                        w.Signal = Math.Max(w.Signal, Marshal.ReadInt32(e, 604));
                        w.Secured = Marshal.ReadInt32(e, 608) != 0;
                        w.Auth = Marshal.ReadInt32(e, 612);
                        w.Cipher = Marshal.ReadInt32(e, 616);
                        w.Connectable = w.Connectable || Marshal.ReadInt32(e, 556) != 0;
                        if ((flags & 1) != 0) w.Connected = true;
                        if ((flags & 2) != 0) {
                            w.Known = true;
                            w.Profile = Marshal.PtrToStringUni(e);
                        }
                    }
                    s.Networks = bySsid.Values.OrderByDescending(x => x.Connected).ThenByDescending(x => x.Signal).ThenBy(x => x.Ssid).ToList();
                } finally { WlanFreeMemory(nets); }
            }

            // The band and channel of the access point in use.
            if (bssid != null) {
                IntPtr bss;
                if (WlanGetNetworkBssList(h, ref id, IntPtr.Zero, 1, false, IntPtr.Zero, out bss) == 0) {
                    try {
                        int n = Marshal.ReadInt32(bss, 4);
                        for (int i = 0; i < n; i++) {
                            IntPtr e = IntPtr.Add(bss, 8 + i * 360);
                            byte[] mac = new byte[6];
                            Marshal.Copy(IntPtr.Add(e, 40), mac, 0, 6);
                            if (!mac.SequenceEqual(bssid)) continue;
                            s.Rssi = Marshal.ReadInt32(e, 56);
                            s.FreqMHz = Marshal.ReadInt32(e, 92) / 1000;
                            s.Band = BandOf(s.FreqMHz);
                            s.Channel = ChannelOf(s.FreqMHz);
                            break;
                        }
                    } finally { WlanFreeMemory(bss); }
                }
            }
        } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }

    // Physical adapters only: no Hyper-V or WSL switch, VPN, loopback, or the
    // Bluetooth personal area network that also calls itself Ethernet.
    public static List<VivacAdapter> GetAdapters() {
        List<VivacAdapter> list = new List<VivacAdapter>();
        foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces()) {
            bool wifi = ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211;
            bool wired = ni.NetworkInterfaceType == NetworkInterfaceType.Ethernet || ni.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet;
            if (!wifi && !wired) continue;
            string d = ni.Description ?? "";
            if (System.Text.RegularExpressions.Regex.IsMatch(d, "Hyper-V|Virtual|VPN|TAP-|Bluetooth|Loopback|WAN Miniport|Npcap|VirtualBox|VMware|WireGuard|Tailscale", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) continue;
            VivacAdapter a = new VivacAdapter();
            a.Id = ni.Id; a.Name = ni.Name; a.Description = d; a.Wifi = wifi;
            a.Up = ni.OperationalStatus == OperationalStatus.Up;
            a.SpeedMbps = ni.Speed > 0 ? ni.Speed / 1000000 : 0;
            byte[] mac = ni.GetPhysicalAddress().GetAddressBytes();
            a.Mac = string.Join(":", mac.Select(b => b.ToString("X2")));
            try {
                IPInterfaceProperties ip = ni.GetIPProperties();
                a.Ipv4 = ip.UnicastAddresses.Where(u => u.Address.AddressFamily == AddressFamily.InterNetwork).Select(u => u.Address.ToString()).ToArray();
                a.Ipv6 = ip.UnicastAddresses.Where(u => u.Address.AddressFamily == AddressFamily.InterNetworkV6 && !u.Address.IsIPv6LinkLocal).Select(u => u.Address.ToString()).ToArray();
                a.Gateways = ip.GatewayAddresses.Select(g => g.Address).Where(g => g.AddressFamily == AddressFamily.InterNetwork && g.ToString() != "0.0.0.0")
                    .Select(g => g.ToString()).ToArray();
                // IPv4 first, then IPv6, each once.
                a.Dns = ip.DnsAddresses.OrderBy(x => x.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).Select(x => x.ToString()).Distinct().ToArray();
                try { a.Dhcp = ip.GetIPv4Properties().IsDhcpEnabled; } catch { }
            } catch { }
            list.Add(a);
        }
        return list;
    }

    public static void Scan(Guid iface) {
        IntPtr h = Open();
        try { WlanScan(h, ref iface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero); } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }

    // Returns 0 on success, or the Win32 error.
    public static int Connect(Guid iface, string profile) {
        IntPtr h = Open();
        try {
            ConnectionParameters p = new ConnectionParameters();
            p.Mode = 0; p.Profile = profile; p.BssType = 1;
            return WlanConnect(h, ref iface, ref p, IntPtr.Zero);
        } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
    public static int Disconnect(Guid iface) {
        IntPtr h = Open();
        try { return WlanDisconnect(h, ref iface, IntPtr.Zero); } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
    public static int Forget(Guid iface, string profile) {
        IntPtr h = Open();
        try { return WlanDeleteProfile(h, ref iface, profile, IntPtr.Zero); } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
    // The profile is handed to Windows directly, so the key never touches
    // the disk outside Windows' own (encrypted) profile store.
    public static int SaveProfile(Guid iface, string xml) {
        IntPtr h = Open();
        try {
            uint reason;
            int rc = WlanSetProfile(h, ref iface, 0, xml, null, true, IntPtr.Zero, out reason);
            // Where policy keeps profiles for every user to administrators,
            // one for this user alone (WLAN_PROFILE_USER).
            if (rc == 5) rc = WlanSetProfile(h, ref iface, 2, xml, null, true, IntPtr.Zero, out reason);
            return rc;
        } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }

    // For the panel's timer to poll: the state is read on a worker thread.
    public static System.Threading.Tasks.Task<VivacWifiState> GetStateAsync() {
        return System.Threading.Tasks.Task.Run(() => GetState());
    }
    public static System.Threading.Tasks.Task ScanAsync(Guid iface) {
        return System.Threading.Tasks.Task.Run(() => { try { Scan(iface); } catch { } });
    }
}
