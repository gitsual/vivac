// "Loading..." with a turning ring, in the palette, for the moment between a
// key and the surface it opens. Without it a slow open (the host building a
// window, or no host at all and a fresh PowerShell) looks like a key that did
// nothing.
//
// It lives on a thread of its own, with its own dispatcher, so the ring keeps
// turning while the caller's thread is busy building the surface. Shown only
// after a short wait, so a surface that opens at once never flashes it; gone
// as soon as a new window of this process is on screen, or after a while
// whatever happens. It never takes the focus.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

public static class VivacLoading {
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    private static Dispatcher ui = null;
    private static Window win = null;
    private static IntPtr own = IntPtr.Zero;
    private static DispatcherTimer watch = null;
    private static HashSet<IntPtr> before = new HashSet<IntPtr>();
    private static DateTime asked;
    private static int generation = 0;
    private const int DelayMs = 150;
    private const int GiveUpMs = 12000;

    private static List<IntPtr> VisibleWindows() {
        uint me = (uint)Process.GetCurrentProcess().Id;
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows((h, d) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == me && h != own && IsWindowVisible(h)) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    private static Brush Hex(string rgb) {
        return new SolidColorBrush((Color)ColorConverter.ConvertFromString("#" + rgb));
    }

    // bg, fg, accent: the palette's COLOR_BG, COLOR_FG and COLOR_ACCENT, as
    // RRGGBB. Called once; Show after that.
    public static void Init(string bg, string fg, string accent, string text) {
        if (ui != null) return;
        ManualResetEvent ready = new ManualResetEvent(false);
        Thread t = new Thread(() => {
            ui = Dispatcher.CurrentDispatcher;
            win = Build(bg, fg, accent, text);
            own = new WindowInteropHelper(win).EnsureHandle();
            watch = new DispatcherTimer(DispatcherPriority.Normal, ui);
            watch.Interval = TimeSpan.FromMilliseconds(40);
            watch.Tick += (s, e) => Tick();
            ready.Set();
            Dispatcher.Run();
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        ready.WaitOne();
    }

    private static Window Build(string bg, string fg, string accent, string text) {
        Window w = new Window();
        // Every vivac window's title starts with "vivac": the key guard's bar
        // watch leaves those alone.
        w.Title = "vivac - loading";
        w.WindowStyle = WindowStyle.None;
        w.AllowsTransparency = true;
        w.Background = Brushes.Transparent;
        w.Topmost = true;
        w.ShowInTaskbar = false;
        w.ShowActivated = false;
        w.Focusable = false;
        w.ResizeMode = ResizeMode.NoResize;
        w.SizeToContent = SizeToContent.WidthAndHeight;
        w.WindowStartupLocation = WindowStartupLocation.CenterScreen;

        Ellipse track = new Ellipse { Width = 22, Height = 22, Stroke = Hex(accent), StrokeThickness = 3, Opacity = 0.25 };
        // A quarter of the ring, turning.
        Ellipse arc = new Ellipse { Width = 22, Height = 22, Stroke = Hex(accent), StrokeThickness = 3 };
        arc.StrokeDashArray = new DoubleCollection(new double[] { 5.5, 100 });
        arc.StrokeDashCap = PenLineCap.Round;
        RotateTransform spin = new RotateTransform(0, 11, 11);
        arc.RenderTransform = spin;
        DoubleAnimation turn = new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(0.9)));
        turn.RepeatBehavior = RepeatBehavior.Forever;
        spin.BeginAnimation(RotateTransform.AngleProperty, turn);
        Grid ring = new Grid { Width = 22, Height = 22, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        ring.Children.Add(track);
        ring.Children.Add(arc);

        TextBlock label = new TextBlock { Text = text, Foreground = Hex(fg), FontSize = 15, VerticalAlignment = VerticalAlignment.Center };
        label.FontFamily = new FontFamily("JetBrainsMono Nerd Font, JetBrainsMono NF, Cascadia Code, Segoe UI");
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(ring);
        row.Children.Add(label);

        Border frame = new Border {
            Background = new SolidColorBrush(Color.FromArgb(0xF2, ((SolidColorBrush)Hex(bg)).Color.R, ((SolidColorBrush)Hex(bg)).Color.G, ((SolidColorBrush)Hex(bg)).Color.B)),
            BorderBrush = Hex(accent), BorderThickness = new Thickness(2), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(20, 14, 22, 14), Child = row,
        };
        w.Content = frame;
        return w;
    }

    // A surface is on its way: the ring shows if it is not on screen soon.
    public static void Show() {
        if (ui == null) return;
        int g = Interlocked.Increment(ref generation);
        ui.BeginInvoke(new Action(() => {
            if (g != generation) return;
            before = new HashSet<IntPtr>(VisibleWindows());
            asked = DateTime.UtcNow;
            watch.Start();
        }));
    }

    // Done, or nothing will come (the surface was closed instead of opened).
    public static void Hide() {
        if (ui == null) return;
        Interlocked.Increment(ref generation);
        ui.BeginInvoke(new Action(() => { watch.Stop(); win.Hide(); }));
    }

    private static void Tick() {
        double waited = (DateTime.UtcNow - asked).TotalMilliseconds;
        foreach (IntPtr h in VisibleWindows()) {
            if (!before.Contains(h)) { watch.Stop(); win.Hide(); return; }
        }
        if (waited > GiveUpMs) { watch.Stop(); win.Hide(); return; }
        if (waited > DelayMs && !win.IsVisible) win.Show();
    }
}
