using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace BisprBlow;

// The floating "flow bar": a small dark pill anchored to an edge of the active screen. Never takes
// focus, so the target app keeps it. States: idle (tiny lozenge, expands on hover with three
// buttons), recording (waveform bars; stop button when hands-free), processing (pulsing dots).
//
// The window is a fixed size, large enough for the biggest state, and only the capsule inside it
// animates. Pixels outside the capsule are fully transparent, and Windows
// hands clicks on those to the window underneath, so no region has to be tracked.
public partial class RecordingPill : Window
{
    const int BarCount = 14;
    // Room for the capsule's shadow to fade out. A shadow wider than the window gets clipped by its
    // edge, and a clipped gaussian reads as a translucent rectangle around the pill.
    const double Margin = 6;

    // The capsule's own size per state: the layout numbers below, and they have to stay in step with
    // the content, since content that outgrows its capsule gets clipped.
    static Size CapsuleSize(DictationController.Phase state) => state switch
    {
        // 3 × 26pt circles + 2 × 7pt spacing + 9pt padding each side.
        DictationController.Phase.Idle => new Size(110, 36),
        // 14 bars × 2.5pt + 13 × 2.5pt spacing + 13pt padding each side, plus the stop button.
        DictationController.Phase.Recording => new Size(93.5, 28),
        DictationController.Phase.Locked => new Size(125.5, 28),
        // 3 × 6pt dots + 2 × 5pt spacing + 14pt padding each side.
        _ => new Size(56, 22),
    };

    // The box a state occupies on a given edge: the capsule plus `Margin` on every side. A side-anchored
    // pill is the same bar turned 90°, so its box is the transpose.
    public static Size PillSize(DictationController.Phase state, PillAnchor anchor)
    {
        var content = CapsuleSize(state);
        var flat = new Size(Math.Ceiling(content.Width + Margin * 2), Math.Ceiling(content.Height + Margin * 2));
        return anchor.IsVertical() ? new Size(flat.Height, flat.Width) : flat;
    }

    // Unrotated, the biggest any state needs; the stage the capsule is laid out in.
    static readonly Size StageSize = Enum.GetValues<DictationController.Phase>()
        .Select(s => PillSize(s, PillAnchor.BottomCentre))
        .Aggregate((a, b) => new Size(Math.Max(a.Width, b.Width), Math.Max(a.Height, b.Height)));

    public static Size WindowSize(PillAnchor anchor) =>
        anchor.IsVertical() ? new Size(StageSize.Height, StageSize.Width) : StageSize;

    readonly DictationController controller;
    readonly PlacementOverlay overlay = new();
    readonly DispatcherTimer repositionTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly Border[] bars = new Border[BarCount];
    readonly float[] waveSamples = new float[BarCount];
    readonly Ellipse[] dots = new Ellipse[3];
    bool hovering;
    bool dotsPulsing;
    bool isHidden = true;
    DateTime dragEndedAt = DateTime.MinValue;
    Rect? lastLayoutFrame;

    public RecordingPill(DictationController controller)
    {
        this.controller = controller;
        InitializeComponent();
        PillScreen.Style(this);
        Width = WindowSize(PillPlacement.Current).Width;
        Height = WindowSize(PillPlacement.Current).Height;
        Stage.Width = StageSize.Width;
        Stage.Height = StageSize.Height;

        for (var i = 0; i < BarCount; i++)
        {
            bars[i] = new Border { Width = 2.5, Height = 3, CornerRadius = new CornerRadius(1.25), VerticalAlignment = VerticalAlignment.Center,
                                   Margin = new Thickness(0, 0, i < BarCount - 1 ? 2.5 : 0, 0) };
            bars[i].SetResourceReference(Border.BackgroundProperty, "Bj.PillWave");
            Wave.Children.Add(bars[i]);
        }
        for (var i = 0; i < dots.Length; i++)
        {
            dots[i] = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(i == 0 ? 0 : 5, 0, 0, 0) };
            dots[i].SetResourceReference(Shape.FillProperty, "Bj.Blue");
            Dots.Children.Add(dots[i]);
        }

        // The capsule's ends are as round as it is tall, at every size it animates through.
        Capsule.SizeChanged += (_, _) =>
        {
            Back.CornerRadius = new CornerRadius(Capsule.ActualHeight / 2);
            Capsule.Clip = new RectangleGeometry(new Rect(0, 0, Capsule.ActualWidth, Capsule.ActualHeight),
                                                 Capsule.ActualHeight / 2, Capsule.ActualHeight / 2);
        };
        Capsule.MouseEnter += (_, _) => SetHovering(true);
        Capsule.MouseLeave += (_, _) => SetHovering(false);
        Stage.PreviewMouseLeftButtonDown += (_, _) => pressedAt = PillScreen.Pointer(PillScreen.UnderPointer());
        Stage.PreviewMouseMove += DragMove;
        Stage.PreviewMouseLeftButtonUp += (_, _) => EndDrag();
        Stage.LostMouseCapture += (_, _) => EndDrag();

        controller.PropertyChanged += OnControllerChanged;
        controller.Levels += OnLevel;
        AppSettings.Shared.PropertyChanged += OnSettingsChanged;
        // Keep the pill pinned across display changes and resolution/DPI switches.
        SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(Reposition);
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Reposition);
        repositionTimer.Tick += (_, _) => Reposition();

        ApplyAnchor();
        Apply(animate: false);
        RefreshHelp();
        ApplyVisibility();
    }

    void OnControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(DictationController.State)) return;
        Apply();
        ApplyVisibility();
        if (controller.State == DictationController.Phase.Recording)
            Dispatcher.BeginInvoke(DispatcherPriority.Render, () => ActivationTrace.Mark("pill"));
    }

    void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.AlwaysShowPill))
            ApplyVisibility();
        // The tooltip names the user's shortcut, so a rebind rewrites it.
        else if (e.PropertyName == nameof(AppSettings.Bindings)) RefreshHelp();
        else if (e.PropertyName == nameof(AppSettings.PillAnchor)) ApplyAnchor();
    }

    void RefreshHelp() =>
        HandsFree.ToolTip = AppSettings.Shared.HoldPhrase is { } phrase
            ? $"Dictate hands-free (or {char.ToLowerInvariant(phrase[0])}{phrase[1..]})"
            : "Dictate hands-free";

    // Fast attack, slow release, like a meter needle. The raw per-buffer level is spiky — speech is
    // mostly gaps — so rising is taken instantly and falling is floored at 82% of the previous
    // sample, which turns a gap into a decaying tail instead of a dropout.
    void OnLevel(float level)
    {
        if (controller.State is not (DictationController.Phase.Recording or DictationController.Phase.Locked)) return;
        var previous = waveSamples[^1];
        Array.Copy(waveSamples, 1, waveSamples, 0, BarCount - 1);
        waveSamples[^1] = Math.Max(level, previous * 0.82f);
        // Bars top out at 16pt inside a 28pt capsule, leaving 6pt of clear pill above and below: a
        // meter wants headroom it visibly never uses.
        for (var i = 0; i < BarCount; i++) bars[i].Height = 3 + waveSamples[i] * 13;
    }

    void SetHovering(bool value)
    {
        if (hovering == value) return;
        hovering = value;
        Apply();
    }

    // One capsule for every state, resized per state, so a change of state morphs the shape rather
    // than swapping one view for another. It hugs the parked edge, so that edge stays put while the
    // rest grows.
    void Apply(bool animate = true)
    {
        var state = controller.State;
        var idle = state == DictationController.Phase.Idle;
        var size = idle && !hovering ? new Size(42, 9) : CapsuleSize(state);
        if (animate)
        {
            PillMotion.To(Capsule, WidthProperty, size.Width);
            PillMotion.To(Capsule, HeightProperty, size.Height);
        }
        else
        {
            Capsule.Width = size.Width;
            Capsule.Height = size.Height;
        }

        // Only what rides on the capsule cross-fades; the shape underneath it morphs.
        var open = idle && hovering;
        Show(HoverRow, open, animate);
        HoverRow.IsHitTestVisible = open;
        PillMotion.To(HoverScale, ScaleTransform.ScaleXProperty, open ? 1 : 0.86);
        PillMotion.To(HoverScale, ScaleTransform.ScaleYProperty, open ? 1 : 0.86);
        Show(RecordingRow, state is DictationController.Phase.Recording or DictationController.Phase.Locked, animate);
        Stop.Visibility = state == DictationController.Phase.Locked ? Visibility.Visible : Visibility.Collapsed;
        RecordingRow.IsHitTestVisible = state == DictationController.Phase.Locked;
        Show(Dots, state == DictationController.Phase.Processing, animate);
        var processing = state == DictationController.Phase.Processing;
        if (processing == dotsPulsing) return;
        dotsPulsing = processing;
        for (var i = 0; i < dots.Length; i++)
            dots[i].BeginAnimation(OpacityProperty, !processing ? null
                : new DoubleAnimation(1, 0.25, TimeSpan.FromSeconds(0.45))
                {
                    AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(i * 0.15),
                    EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
                });
    }

    static void Show(UIElement row, bool visible, bool animate)
    {
        if (animate) PillMotion.To(row, OpacityProperty, visible ? 1 : 0, PillMotion.Snap);
        else row.Opacity = visible ? 1 : 0;
    }

    // The window turns and moves as one thing with the anchor: a side anchor turns the pill 90° and
    // transposes its window.
    void ApplyAnchor()
    {
        var anchor = PillPlacement.Current;
        var window = WindowSize(anchor);
        Width = window.Width;
        Height = window.Height;
        Canvas.SetLeft(Stage, (window.Width - StageSize.Width) / 2);
        Canvas.SetTop(Stage, (window.Height - StageSize.Height) / 2);
        Turn.Angle = anchor.Rotation();
        Capsule.VerticalAlignment = anchor.ContentAlignment();
        // The glyphs counter-rotate: the bar turns on a side edge, but an icon lying on its side is
        // wrong to look at. The capsule and the waveform still turn with the bar.
        var upright = new RotateTransform(-anchor.Rotation());
        foreach (var glyph in new UIElement[] { (UIElement)HandsFree.Content, (UIElement)Open.Content, (UIElement)Recent.Content })
            glyph.RenderTransform = upright;
        Reposition();
    }

    // Follow the screen the user is working on, not the launch screen.
    void Reposition()
    {
        if (isHidden) return;
        var screen = PillScreen.Active();
        var frame = screen.LayoutFrame;
        // Logged on change only: the right frame depends on the taskbar's setting and what the
        // frontmost app does in fullscreen, so this line says which frame it chose.
        if (frame != lastLayoutFrame)
        {
            lastLayoutFrame = frame;
            Log.Line($"layout frame={frame} screen={screen.Full} work={screen.Work} scale={screen.Scale}");
        }
        var size = WindowSize(PillPlacement.Current);
        PillScreen.Place(this, new Rect(PillPlacement.Current.Origin(size, frame), size), screen);
    }

    // Hiding the idle pill is a visibility setting, not a state: it still has to appear the
    // moment a dictation starts. Both inputs drive it, and idle is the only state that hides.
    void ApplyVisibility() =>
        SetHidden(!AppSettings.Shared.AlwaysShowPill && controller.State == DictationController.Phase.Idle);

    // A hidden pill takes no clicks and holds no place, so the reposition timer runs only while it shows.
    void SetHidden(bool hidden)
    {
        if (hidden == isHidden && IsVisible == !hidden) return;
        isHidden = hidden;
        if (hidden)
        {
            repositionTimer.Stop();
            Hide();
            return;
        }
        repositionTimer.Start();
        Reposition();
    }

    // ---- Dragging the pill to a new place

    // Dragging picks a place for it: the screen dims, three targets appear, and the pill is replaced
    // by an icon riding the cursor. The window does not move.
    Point? pressedAt;
    bool placing;
    IntPtr overlayScreen;

    void DragMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || pressedAt is not { } start) return;
        var screen = PillScreen.UnderPointer();
        var point = PillScreen.Pointer(screen);
        if (!placing)
        {
            if ((point - start).Length < 6) return;
            placing = true;
            // The drag is hosted in this window, so taking the mouse keeps it ours even once the
            // window is drawn invisible; hiding it outright would end the drag on the spot.
            Stage.CaptureMouse();
            Stage.Opacity = 0;
        }
        if (overlayScreen != screen.Handle)
        {
            overlayScreen = screen.Handle;
            overlay.Begin(screen);
        }
        overlay.Update(screen, point);
    }

    void EndDrag()
    {
        pressedAt = null;
        if (!placing) return;
        placing = false;
        overlayScreen = IntPtr.Zero;
        dragEndedAt = DateTime.Now;
        var screen = PillScreen.UnderPointer();
        overlay.End();
        Stage.ReleaseMouseCapture();
        Stage.Opacity = 1;
        if (PillPlacement.Containing(PillScreen.Pointer(screen), screen.LayoutFrame) is not { } target || target == PillPlacement.Current) return;
        AppSettings.Shared.PillAnchor = target.ToString();
    }

    // Every pill button goes through here. The drag runs alongside the buttons, so a release back
    // over the pill lands on whichever button is under the cursor — on the Mac that started a real
    // hands-free dictation that recorded until the app was killed. The tap arrives after the drag
    // ends, so the guard is a short window rather than a flag cleared on release.
    void Tapped(Action action)
    {
        if ((DateTime.Now - dragEndedAt).TotalSeconds > 0.25) action();
    }

    void StartHandsFree(object sender, RoutedEventArgs e) => Tapped(controller.StartHandsFree);
    void StopHandsFree(object sender, RoutedEventArgs e) => Tapped(controller.StopHandsFree);
    void OpenHome(object sender, RoutedEventArgs e) => Tapped(() => DashboardWindow.Show(DashboardSection.Home));
    void OpenHistory(object sender, RoutedEventArgs e) => Tapped(() => DashboardWindow.Show(DashboardSection.History));
    void Quit(object sender, RoutedEventArgs e) => Application.Current.Shutdown();
}
