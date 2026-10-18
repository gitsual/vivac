// The menu's rows, their icons and their ranking (lib/Surfaces.psm1, Show-Menu).
//
// Icons are what Explorer itself draws for an item: an application of the
// Start menu (shell:AppsFolder\<AppID>), a file, a folder. Asking the shell
// for one takes a few milliseconds, too long for hundreds of rows on every
// keypress, so each is asked for once, on a thread of its own, and kept; a
// row shows its glyph until its icon arrives.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

public static class VivacIcons {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory { [PreserveSig] int GetImage(Size2 size, int flags, out IntPtr bitmap); }
    [StructLayout(LayoutKind.Sequential)] private struct Size2 { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] private struct GdiBitmap { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfoHeader { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHCreateItemFromParsingName(string path, IntPtr bc, ref Guid riid, out IShellItemImageFactory item);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] private static extern int GetObject(IntPtr h, int size, out GdiBitmap bm);
    [DllImport("gdi32.dll")] private static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, [Out] byte[] bits, ref BitmapInfoHeader bi, uint usage);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    private static readonly ConcurrentDictionary<string, ImageSource> cache = new ConcurrentDictionary<string, ImageSource>(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, bool> missing = new ConcurrentDictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
    private static readonly BlockingCollection<KeyValuePair<string, Action>> work = new BlockingCollection<KeyValuePair<string, Action>>();
    private static Thread worker = null;
    public static int Size = 48;

    public static ImageSource Get(string key) {
        ImageSource s;
        return cache.TryGetValue(key, out s) ? s : null;
    }
    public static bool IsMissing(string key) { return missing.ContainsKey(key); }

    // Done is called on the icon thread once the icon is in the cache.
    public static void Request(string key, Action done) {
        if (string.IsNullOrEmpty(key) || cache.ContainsKey(key) || missing.ContainsKey(key)) return;
        Start();
        work.Add(new KeyValuePair<string, Action>(key, done));
    }
    public static void Warm(string[] keys) { foreach (string k in keys) Request(k, null); }

    private static void Start() {
        lock (work) {
            if (worker != null) return;
            worker = new Thread(() => {
                foreach (KeyValuePair<string, Action> item in work.GetConsumingEnumerable()) {
                    if (!cache.ContainsKey(item.Key) && !missing.ContainsKey(item.Key)) {
                        ImageSource s = null;
                        try { s = Load(item.Key, Size); } catch { }
                        if (s != null) cache[item.Key] = s; else missing[item.Key] = true;
                    }
                    if (item.Value != null && cache.ContainsKey(item.Key)) { try { item.Value(); } catch { } }
                }
            });
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.STA);
            worker.Start();
        }
    }

    private static ImageSource Load(string path, int size) {
        Guid iid = typeof(IShellItemImageFactory).GUID;
        IShellItemImageFactory factory;
        if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory) != 0 || factory == null) return null;
        IntPtr bitmap = IntPtr.Zero;
        try {
            Size2 want; want.cx = size; want.cy = size;
            // SIIGBF_ICONONLY: the icon, never a thumbnail of the file's content.
            if (factory.GetImage(want, 0x4, out bitmap) != 0 || bitmap == IntPtr.Zero) return null;
            GdiBitmap bm;
            if (GetObject(bitmap, Marshal.SizeOf(typeof(GdiBitmap)), out bm) == 0) return null;
            int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
            BitmapInfoHeader bi = new BitmapInfoHeader();
            bi.biSize = 40; bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32;
            byte[] px = new byte[w * h * 4];
            IntPtr dc = GetDC(IntPtr.Zero);
            try { if (GetDIBits(dc, bitmap, 0, (uint)h, px, ref bi, 0) == 0) return null; }
            finally { ReleaseDC(IntPtr.Zero, dc); }
            // Old icons carry no alpha at all: opaque, then, not invisible.
            bool alpha = false;
            for (int i = 3; i < px.Length; i += 4) { if (px[i] != 0) { alpha = true; break; } }
            if (!alpha) { for (int i = 3; i < px.Length; i += 4) px[i] = 255; }
            BitmapSource b = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, px, w * 4);
            b.Freeze();
            return b;
        } finally {
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            Marshal.ReleaseComObject(factory);
        }
    }
}

public class VivacMenuRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    private string name, sub;
    private bool urgent;
    public string Name { get { return name; } set { name = value; Raise("Name"); } }
    public string Sub { get { return sub; } set { sub = value; Raise("Sub"); } }
    public bool Urgent { get { return urgent; } set { urgent = value; Raise("Urgent"); } }
    public string Glyph { get; set; }
    public string Group { get; set; }
    public string Section { get; set; }
    public string IconKey { get; set; }
    // Name and group, lower case and without accents, for matching.
    public string Key { get; set; }
    public string NameKey { get; set; }
    public double Uses { get; set; }
    public object Entry { get; set; }

    public ImageSource Icon {
        get {
            if (string.IsNullOrEmpty(IconKey)) return null;
            ImageSource s = VivacIcons.Get(IconKey);
            if (s == null) {
                VivacIcons.Request(IconKey, () => ui.BeginInvoke(new Action(() => { Raise("Icon"); Raise("ShowGlyph"); })));
            }
            return s;
        }
    }
    public bool ShowGlyph { get { return string.IsNullOrEmpty(IconKey) || VivacIcons.Get(IconKey) == null; } }

    private void Raise(string property) {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(property));
    }

    public VivacMenuRow InSection(string section) {
        VivacMenuRow r = (VivacMenuRow)MemberwiseClone();
        r.PropertyChanged = null;
        r.Section = section;
        return r;
    }
}

public static class VivacMenuRank {
    // Every word must appear in the row's key. A name that starts with the
    // first word beats one where a word starts with it, which beats one that
    // only contains it; what is used often climbs. Groups come in the order
    // of their best row, rows in the order of their score, ties as given.
    public static List<VivacMenuRow> Filter(IList<VivacMenuRow> rows, string[] words) {
        List<KeyValuePair<double, VivacMenuRow>> hits = new List<KeyValuePair<double, VivacMenuRow>>();
        Dictionary<string, double> best = new Dictionary<string, double>();
        foreach (VivacMenuRow r in rows) {
            bool all = true;
            foreach (string w in words) { if (r.Key.IndexOf(w, StringComparison.Ordinal) < 0) { all = false; break; } }
            if (!all) continue;
            double score = 0;
            if (words.Length > 0) {
                string f = words[0];
                if (r.NameKey.StartsWith(f, StringComparison.Ordinal)) score = 300;
                else if (r.NameKey.IndexOf(" " + f, StringComparison.Ordinal) >= 0) score = 200;
                else if (r.NameKey.IndexOf(f, StringComparison.Ordinal) >= 0) score = 100;
            }
            score += Math.Min(r.Uses, 40) * 3;
            hits.Add(new KeyValuePair<double, VivacMenuRow>(score, r));
            double b;
            if (!best.TryGetValue(r.Group, out b) || score > b) best[r.Group] = score;
        }
        List<int> order = new List<int>();
        for (int i = 0; i < hits.Count; i++) order.Add(i);
        order.Sort((a, c) => {
            int g = best[hits[c].Value.Group].CompareTo(best[hits[a].Value.Group]);
            if (g != 0) return g;
            int s = string.CompareOrdinal(hits[a].Value.Group, hits[c].Value.Group);
            if (s != 0) return s;
            int k = hits[c].Key.CompareTo(hits[a].Key);
            return k != 0 ? k : a.CompareTo(c);
        });
        List<VivacMenuRow> result = new List<VivacMenuRow>();
        foreach (int i in order) result.Add(hits[i].Value);
        return result;
    }
}
