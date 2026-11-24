using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace BisprBlow;

// Transient message above the pill: the mic that just changed, a paste fallback, a progress line, a
// word just learned. Its own window rather than a wider pill, so a long message never grows the
// pill's footprint. Click-through while it is only information — it takes the mouse only when it
// carries a button, which is what lets the pointer rest on it to hold it open.
public partial class PillToast : Window
{
    readonly DictationController controller;
    readonly DispatcherTimer repositionTimer = new() { Interval = TimeSpan.FromSeconds(2) };

    public PillToast(DictationController controller)
    {
        this.controller = controller;
        InitializeComponent();
        PillScreen.Style(this, clickThrough: true);
        controller.PropertyChanged += OnControllerChanged;
        AppSettings.Shared.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(AppSettings.PillAnchor)) return;
            Align();
            Reposition();
        };
        // Same re-pin as the pill, so the toast follows it after a drag. Only while there is something
        // to show: an empty toast has nowhere it needs to be.
        repositionTimer.Tick += (_, _) => Reposition();
        Align();
        Reposition();
        Refresh();
    }

    void OnControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(DictationController.Notice) or nameof(DictationController.MicFlash)
            or nameof(DictationController.NoticeAction)) Refresh();
    }

    // A notice is something the user needs; a mic change is something they might like to know.
    string? Current =>
        !string.IsNullOrEmpty(controller.Notice) ? controller.Notice
        : !string.IsNullOrEmpty(controller.MicFlash) ? controller.MicFlash : null;

    void Refresh()
    {
        var action = controller.NoticeAction;
        PillScreen.ClickThrough(this, action == null);
        if (Current is { } message)
        {
            Message.Text = message;
            MicGlyph.Visibility = controller.Notice == null ? Visibility.Visible : Visibility.Collapsed;
            Action.Visibility = action == null ? Visibility.Collapsed : Visibility.Visible;
            ActionLabel.Text = action?.Label;
            if (Capsule.Visibility != Visibility.Visible)
            {
                Reposition();
                repositionTimer.Start();
                Capsule.Visibility = Visibility.Visible;
            }
            PillMotion.To(Capsule, OpacityProperty, 1);
            PillMotion.To(Lift, TranslateTransform.YProperty, 0);
            return;
        }
        repositionTimer.Stop();
        var fade = new DoubleAnimation(0, PillMotion.Soft);
        fade.Completed += (_, _) =>
        {
            if (Current == null) Capsule.Visibility = Visibility.Collapsed;
        };
        Capsule.BeginAnimation(OpacityProperty, fade);
        PillMotion.To(Lift, TranslateTransform.YProperty, 6);
    }

    void Hovered(object sender, System.Windows.Input.MouseEventArgs e) => controller.NoticeHovered = true;
    void Unhovered(object sender, System.Windows.Input.MouseEventArgs e) => controller.NoticeHovered = false;
    void RunAction(object sender, RoutedEventArgs e) => controller.NoticeAction?.Run();

    // The same parked edge the pill hugs, so the capsule lands against it.
    void Align() =>
        (Capsule.HorizontalAlignment, Capsule.VerticalAlignment) = PillPlacement.Current switch
        {
            PillAnchor.LeftCentre => (HorizontalAlignment.Left, VerticalAlignment.Center),
            PillAnchor.RightCentre => (HorizontalAlignment.Right, VerticalAlignment.Center),
            _ => (HorizontalAlignment.Center, VerticalAlignment.Bottom),
        };

    // Sits against the pill wherever it is parked, so the two read as one thing: above it on the
    // bottom edge, and BESIDE it on a side edge. Above is what put the message halfway up an empty
    // screen, since a side-anchored pill is a tall bar at the vertical centre.
    void Reposition()
    {
        var screen = PillScreen.Active();
        var frame = screen.LayoutFrame;
        var size = new Size(Width, Height);
        var anchor = PillPlacement.Current;
        var pillSize = RecordingPill.PillSize(DictationController.Phase.Idle, anchor);
        var pill = new Rect(anchor.Origin(pillSize, frame), pillSize);
        var spot = anchor switch
        {
            PillAnchor.LeftCentre => new Point(pill.Right + 4, pill.Top + (pill.Height - size.Height) / 2),
            PillAnchor.RightCentre => new Point(pill.Left - size.Width - 4, pill.Top + (pill.Height - size.Height) / 2),
            _ => new Point(pill.Left + (pill.Width - size.Width) / 2, pill.Top - size.Height - 4),
        };
        var origin = new Point(Math.Clamp(spot.X, frame.Left, Math.Max(frame.Left, frame.Right - size.Width)),
                               Math.Clamp(spot.Y, frame.Top, Math.Max(frame.Top, frame.Bottom - size.Height)));
        PillScreen.Place(this, new Rect(origin, size), screen);
    }
}
