using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace BisprBlow;

// Where the user parked the pill. The taskbar, tray icons and the frontmost app compete for the same
// edges, so this is a preference rather than a constant. Geometry is in device-independent units of
// one monitor, y down from the top-left.
public enum PillAnchor { BottomCentre, LeftCentre, RightCentre }

public static class PillPlacement
{
    public static PillAnchor Current =>
        Enum.TryParse<PillAnchor>(AppSettings.Shared.PillAnchor, out var a) ? a : PillAnchor.BottomCentre;

    // On a side edge the pill turns 90°, so its window's width and height swap.
    public static bool IsVertical(this PillAnchor a) => a != PillAnchor.BottomCentre;

    // The two edges turn opposite ways so the bar always leans away from the screen edge it is parked on.
    public static double Rotation(this PillAnchor a) => a switch
    {
        PillAnchor.LeftCentre => -90,
        PillAnchor.RightCentre => 90,
        _ => 0,
    };

    // Which edge of its own box the bar sits against, in the UNROTATED space; `Rotation` maps that onto
    // the parked screen edge, so both side anchors want Top and only the bottom anchor wants Bottom.
    public static VerticalAlignment ContentAlignment(this PillAnchor a) =>
        a == PillAnchor.BottomCentre ? VerticalAlignment.Bottom : VerticalAlignment.Top;

    const double Inset = 4;

    // Top-left origin for a window of `size`, within the frame the pill lays out in. The inset keeps
    // the side anchors off the bezel.
    public static Point Origin(this PillAnchor a, Size size, Rect frame) => a switch
    {
        PillAnchor.BottomCentre => new Point(frame.Left + (frame.Width - size.Width) / 2, frame.Bottom - size.Height),
        PillAnchor.LeftCentre => new Point(frame.Left + Inset, frame.Top + (frame.Height - size.Height) / 2),
        _ => new Point(frame.Right - size.Width - Inset, frame.Top + (frame.Height - size.Height) / 2),
    };

    // Exactly where the pill lands here, so the target the user sees while placing is the shape they
    // get, turned the way it will be turned.
    public static Rect Landing(this PillAnchor a, Rect frame)
    {
        var size = RecordingPill.PillSize(DictationController.Phase.Idle, a);
        return new Rect(a.Origin(size, frame), size);
    }

    // The catch area around a landing spot. Generous, because the placeholder is only pill sized. The
    // highlight is driven off this same rect, so a lit target always means a hit.
    public static Rect Zone(this PillAnchor a, Rect frame)
    {
        var landing = a.Landing(frame);
        landing.Inflate(64, 64);
        return landing;
    }

    // The zone a point is inside, or null. Deliberately not a nearest-match: releasing away from every
    // target leaves the pill where it is.
    public static PillAnchor? Containing(Point point, Rect frame) =>
        Enum.GetValues<PillAnchor>().Cast<PillAnchor?>().FirstOrDefault(a => a!.Value.Zone(frame).Contains(point));

    // Placement and anchor asserts for `--self-check`, ported from SelfCheckInput.swift. Screen is
    // y-down here where the Mac's is y-up, so the bottom anchor's origin is 830 rather than 0.
    public static void SelfCheck()
    {
        var screen = new Rect(0, 0, 1352, 878);
        var pill = new Size(122, 48);
        Check.Equal(Containing(new Point(60, 438), screen), PillAnchor.LeftCentre);
        Check.Equal(Containing(new Point(1300, 438), screen), PillAnchor.RightCentre);
        Check.Equal(Containing(new Point(676, 858), screen), PillAnchor.BottomCentre);
        // Released in open space: null, so the pill stays where it was instead of being flung to
        // whichever target happened to be closest.
        Check.Equal(Containing(new Point(676, 438), screen), null);
        // The lit target is the landing spot, so a point inside a zone must be near its landing.
        Check.That(PillAnchor.LeftCentre.Zone(screen).Contains(new Point(60, 438)));
        Check.Equal(PillAnchor.LeftCentre.Landing(screen).Size, new Size(48, 122));
        Check.Equal(PillAnchor.LeftCentre.Origin(pill, screen), new Point(4, 415));
        Check.Equal(PillAnchor.RightCentre.Origin(pill, screen), new Point(1226, 415));
        Check.Equal(PillAnchor.BottomCentre.Origin(pill, screen), new Point(615, 830));
        // The bar hugs its box's edge, and `Rotation` maps that local edge onto the parked screen edge.
        // Out of step and the sliver drifts to the middle of the box, or to the wrong side.
        Check.Equal(PillAnchor.BottomCentre.ContentAlignment(), VerticalAlignment.Bottom);
        Check.That(PillAnchor.LeftCentre.ContentAlignment() == VerticalAlignment.Top
                   && PillAnchor.RightCentre.ContentAlignment() == VerticalAlignment.Top);
        // A side-anchored pill is the same bar turned 90°, so its box is the transpose. If these ever
        // disagree the window clips the pill.
        var flat = RecordingPill.PillSize(DictationController.Phase.Idle, PillAnchor.BottomCentre);
        Check.Equal(RecordingPill.PillSize(DictationController.Phase.Idle, PillAnchor.LeftCentre), new Size(flat.Height, flat.Width));
        Check.That(PillAnchor.LeftCentre.IsVertical() && !PillAnchor.BottomCentre.IsVertical());
        // The window is as big as the largest state, so no state resizes it mid-animation.
        foreach (var state in Enum.GetValues<DictationController.Phase>())
            foreach (var anchor in Enum.GetValues<PillAnchor>())
            {
                var need = RecordingPill.PillSize(state, anchor);
                var have = RecordingPill.WindowSize(anchor);
                Check.That(need.Width <= have.Width && need.Height <= have.Height);
            }
    }
}

// One monitor, as the pill sees it: both rects in device-independent units at that monitor's own
// scale, so a window placed with `PillScreen.Place` lands the same size on every display.
sealed record PillMonitor(IntPtr Handle, Rect Work, Rect Full, double Scale)
{
    // The rect the pill is laid out in: the work area normally, so the bar sits on the taskbar's top
    // edge rather than covering it, and the whole monitor when an app is covering the taskbar.
    public Rect LayoutFrame => PillScreen.IsFullScreen(this) ? Full : Work;
}

// The Win32 the pill, its toast and the placement overlay share: which monitor, where, and the window
// styles that keep a topmost window from ever taking focus.
static class PillScreen
{
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int Size; public RECT Monitor, Work; public int Flags; }

    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, int flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, int flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] internal static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);

    const int GwlExStyle = -20, NoActivate = 0x08000000, ToolWindow = 0x80, Transparent = 0x20, Topmost = 8;
    const int MonitorNearest = 2;
    const uint NoActivateFlag = 0x10;
    static readonly IntPtr TopmostHandle = new(-1);

    static PillMonitor Describe(IntPtr monitor)
    {
        var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(monitor, ref info);
        var scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1;
        Rect Dip(RECT r) => new(r.Left / scale, r.Top / scale, (r.Right - r.Left) / scale, (r.Bottom - r.Top) / scale);
        return new PillMonitor(monitor, Dip(info.Work), Dip(info.Monitor), scale);
    }

    // The display the user is looking at: the one holding the foreground window, else the one under
    // the pointer (nothing is foreground on a bare desktop).
    public static PillMonitor Active()
    {
        var front = ContextDetector.ForegroundWindow();
        return front != IntPtr.Zero ? Describe(MonitorFromWindow(front, MonitorNearest)) : UnderPointer();
    }

    public static PillMonitor UnderPointer()
    {
        GetCursorPos(out var p);
        return Describe(MonitorFromPoint(p, MonitorNearest));
    }

    public static Point Pointer(PillMonitor monitor)
    {
        GetCursorPos(out var p);
        return new Point(p.X / monitor.Scale, p.Y / monitor.Scale);
    }

    // Whether an ordinary window covers the whole monitor, so the taskbar is not there and the pill
    // should drop past its strip. The desktop itself covers it too, and is not an app.
    public static bool IsFullScreen(PillMonitor monitor)
    {
        var front = ContextDetector.ForegroundWindow();
        if (front == IntPtr.Zero || front == GetShellWindow() || !GetWindowRect(front, out var r)) return false;
        var scale = monitor.Scale;
        return MonitorFromWindow(front, MonitorNearest) == monitor.Handle
               && r.Left / scale <= monitor.Full.Left + 1 && r.Top / scale <= monitor.Full.Top + 1
               && r.Right / scale >= monitor.Full.Right - 1 && r.Bottom / scale >= monitor.Full.Bottom - 1;
    }

    // Never focused, never in Alt-Tab, always on top. `clickThrough` makes the whole window invisible
    // to the mouse; the pill leaves it off and relies on its transparent pixels instead.
    public static void Style(Window window, bool clickThrough = false) =>
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            SetWindowLong(hwnd, GwlExStyle, GetWindowLong(hwnd, GwlExStyle) | NoActivate | ToolWindow | Topmost
                                            | (clickThrough ? Transparent : 0));
        };

    public static void ClickThrough(Window window, bool on)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var style = GetWindowLong(hwnd, GwlExStyle);
        SetWindowLong(hwnd, GwlExStyle, on ? style | Transparent : style & ~Transparent);
    }

    // In physical pixels rather than through Left/Top: those are converted at whatever DPI the window
    // currently has, which is the wrong monitor's for the one move that crosses displays.
    public static void Place(Window window, Rect dips, PillMonitor monitor)
    {
        // Shown off screen first, so its first frame is never at the default position.
        if (!window.IsVisible)
        {
            window.Left = window.Top = -32000;
            window.Show();
        }
        var hwnd = new WindowInteropHelper(window).Handle;
        SetWindowPos(hwnd, TopmostHandle, (int)Math.Round(dips.X * monitor.Scale), (int)Math.Round(dips.Y * monitor.Scale),
                     (int)Math.Round(dips.Width * monitor.Scale), (int)Math.Round(dips.Height * monitor.Scale),
                     NoActivateFlag);
    }
}

// Eases one property to a value over a theme duration. The pill's motion all comes from here, so
// `Bj.Snap` and `Bj.Soft` stay the only timings.
static class PillMotion
{
    public static Duration Snap => (Duration)Application.Current.FindResource("Bj.Snap");
    public static Duration Soft => (Duration)Application.Current.FindResource("Bj.Soft");

    public static void To(IAnimatable target, DependencyProperty property, double value, Duration? duration = null) =>
        target.BeginAnimation(property, new DoubleAnimation(value, duration ?? Soft) { EasingFunction = new CubicEase() });
}

// Dims the screen and shows where the pill can go while the user drags it. Click-through, like the
// toast: the drag it belongs to is already tracked by the pill, and a full-screen window that
// accepted mouse events would swallow the whole screen.
sealed class PlacementOverlay : Window
{
    // Big enough to read as the pill's stand-in, small enough not to cover the target it is dropped on.
    const double ProxySize = 40;

    readonly Canvas canvas = new();
    readonly Rectangle dim = new() { Fill = Brushes.Black, Opacity = 0, IsHitTestVisible = false };
    readonly Dictionary<PillAnchor, Border> targets = [];
    readonly FrameworkElement proxy;
    PillAnchor? highlighted;

    public PlacementOverlay()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        PillScreen.Style(this, clickThrough: true);

        canvas.Children.Add(dim);
        foreach (var anchor in Enum.GetValues<PillAnchor>())
        {
            var target = new Border
            {
                Background = Brushes.White, Opacity = 0.28, BorderBrush = Brushes.White, BorderThickness = new Thickness(1),
                RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 8, ShadowDepth = 2, Opacity = 0 },
            };
            targets[anchor] = target;
            canvas.Children.Add(target);
        }
        proxy = new Rectangle { Fill = Brushes.White, OpacityMask = new ImageBrush((ImageSource)Application.Current.FindResource("Bj.Logo.Mono")) };
        proxy.Width = proxy.Height = ProxySize;
        proxy.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 10, ShadowDepth = 3, Opacity = 0.4 };
        canvas.Children.Add(proxy);
        Content = canvas;
    }

    // The overlay covers the monitor `screen` is on, and the targets lay out inside its layout frame.
    public void Begin(PillMonitor screen)
    {
        PillScreen.Place(this, screen.Full, screen);
        dim.Width = screen.Full.Width;
        dim.Height = screen.Full.Height;
        var frame = screen.LayoutFrame;
        foreach (var (anchor, target) in targets)
        {
            var landing = anchor.Landing(frame);
            target.Width = landing.Width;
            target.Height = landing.Height;
            target.CornerRadius = new CornerRadius(Math.Min(landing.Width, landing.Height) / 2.2);
            Canvas.SetLeft(target, landing.X - screen.Full.X);
            Canvas.SetTop(target, landing.Y - screen.Full.Y);
        }
        PillMotion.To(dim, OpacityProperty, 0.34);
    }

    // `cursor` is in the same units as the frame the targets were laid out in.
    public void Update(PillMonitor screen, Point cursor)
    {
        Canvas.SetLeft(proxy, cursor.X - screen.Full.X - ProxySize / 2);
        Canvas.SetTop(proxy, cursor.Y - screen.Full.Y - ProxySize / 2);
        var now = PillPlacement.Containing(cursor, screen.LayoutFrame);
        if (now == highlighted) return;
        highlighted = now;
        foreach (var (anchor, target) in targets)
        {
            var lit = anchor == now;
            PillMotion.To(target, OpacityProperty, lit ? 0.95 : 0.28, PillMotion.Snap);
            PillMotion.To(((ScaleTransform)target.RenderTransform), ScaleTransform.ScaleXProperty, lit ? 1.08 : 1, PillMotion.Snap);
            PillMotion.To(((ScaleTransform)target.RenderTransform), ScaleTransform.ScaleYProperty, lit ? 1.08 : 1, PillMotion.Snap);
            PillMotion.To(target.Effect, System.Windows.Media.Effects.DropShadowEffect.OpacityProperty, lit ? 0.25 : 0, PillMotion.Snap);
        }
    }

    public void End()
    {
        highlighted = null;
        Hide();
        dim.BeginAnimation(OpacityProperty, null);
        dim.Opacity = 0;
    }
}
