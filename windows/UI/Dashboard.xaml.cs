using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace BisprBlow;

public enum DashboardSection { Home, History, Dictionary, Team, Settings }

// Main window ("Hub"): sidebar navigation + content pane. One window, reused: a second Show brings the
// open one forward onto the page asked for.
public partial class DashboardWindow : Window
{
    static DashboardWindow? instance;

    readonly Dictionary<DashboardSection, RadioButton> nav;

    DashboardWindow()
    {
        InitializeComponent();
        nav = new()
        {
            [DashboardSection.Home] = NavHome, [DashboardSection.History] = NavHistory,
            [DashboardSection.Dictionary] = NavDictionary, [DashboardSection.Team] = NavTeam,
            [DashboardSection.Settings] = NavSettings,
        };
        VersionLabel.Text = "Version " + (UpdateChecker.Current ?? "dev");
        SourceInitialized += (_, _) => Chrome.Apply(this);
        Theme.ThemeChanged += OnThemeChanged;
        Closed += (_, _) =>
        {
            Theme.ThemeChanged -= OnThemeChanged;
            instance = null;
        };
        OnThemeChanged();
    }

    public static void Show(DashboardSection section = DashboardSection.Home)
    {
        var win = instance ??= new DashboardWindow();
        win.nav[section].IsChecked = true;
        // Centre on the screen the user is on (the pointer), not the primary: the pill never takes
        // focus, so the active window can be on a different display entirely.
        var area = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(win);
        win.WindowStartupLocation = WindowStartupLocation.Manual;
        win.Left = (area.X + (area.Width - win.Width * dpi.DpiScaleX) / 2) / dpi.DpiScaleX;
        win.Top = (area.Y + (area.Height - win.Height * dpi.DpiScaleY) / 2) / dpi.DpiScaleY;
        if (win.WindowState == WindowState.Minimized) win.WindowState = WindowState.Normal;
        ((Window)win).Show();
        win.Activate();
    }

    // Theme.Apply can run on whichever thread noticed the system switch to dark.
    void OnThemeChanged() => Dispatcher.BeginInvoke(() =>
    {
        var look = AppSettings.Shared.Appearance;
        Logo.Source = (ImageSource)FindResource(look.IsDark() ? "Bj.Logo.BlueDark" : "Bj.Logo.Blue");
        var image = look.PaletteFor().SidebarImage;
        SidebarImage.Source = image is null ? null : new BitmapImage(new Uri($"pack://application:,,,/Resources/{image}"));
        SidebarImage.Visibility = image is null ? Visibility.Collapsed : Visibility.Visible;
        if (IsLoaded || new WindowInteropHelper(this).Handle != 0) Chrome.Apply(this);
    });

    void NavChecked(object sender, RoutedEventArgs e)
    {
        var section = nav.First(p => p.Value == sender).Key;
        // A fresh view per visit, as on the Mac: a page opens at its top, not wherever it was left.
        Host.Content = section switch
        {
            DashboardSection.Home => new HomeView(),
            DashboardSection.History => new HistoryView(),
            DashboardSection.Dictionary => new DictionaryView(),
            DashboardSection.Team => new DashboardTeam(),
            _ => new SettingsView(),
        };
        if (!SystemParameters.ClientAreaAnimation || !IsLoaded) return;
        Host.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, (Duration)FindResource("Bj.Soft")) { EasingFunction = (IEasingFunction)FindResource("Bj.Ease") });
        Rise.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(10, 0, (Duration)FindResource("Bj.Soft")) { EasingFunction = (IEasingFunction)FindResource("Bj.Ease") });
    }
}

// The title bar is Windows', so it is told about the palette: dark mode for the caption buttons, and on
// Windows 11 the palette's own colours for the bar.
static class Chrome
{
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static void Apply(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var look = AppSettings.Shared.Appearance;
        var palette = look.PaletteFor();
        var dark = look.IsDark() ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref dark, 4);  // DWMWA_USE_IMMERSIVE_DARK_MODE
        var caption = Colorref(palette.Cream);
        var text = Colorref(palette.Ink);
        DwmSetWindowAttribute(hwnd, 35, ref caption, 4);  // DWMWA_CAPTION_COLOR, Windows 11 only
        DwmSetWindowAttribute(hwnd, 36, ref text, 4);  // DWMWA_TEXT_COLOR
    }

    static int Colorref(Color c) => c.R | c.G << 8 | c.B << 16;
}

// Shared page scaffold: big title, optional subtitle, then the page's sections. The template is in
// Styles.xaml.
public class DashboardPage : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(DashboardPage), new("" ));
    public static readonly DependencyProperty SubtitleProperty = DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(DashboardPage), new(""));

    static DashboardPage() =>
        DefaultStyleKeyProperty.OverrideMetadata(typeof(DashboardPage), new FrameworkPropertyMetadata(typeof(DashboardPage)));

    public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public string Subtitle { get => (string)GetValue(SubtitleProperty); set => SetValue(SubtitleProperty, value); }
}

// A vertical stack with a gap between children, which StackPanel cannot do. Collapsed children take no gap.
public class VStack : Panel
{
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(VStack),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsArrange));

    public double Spacing { get => (double)GetValue(SpacingProperty); set => SetValue(SpacingProperty, value); }

    protected override Size MeasureOverride(Size available)
    {
        double height = 0, width = 0;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(available.Width, double.PositiveInfinity));
            if (child.Visibility == Visibility.Collapsed) continue;
            if (height > 0) height += Spacing;
            height += child.DesiredSize.Height;
            width = Math.Max(width, child.DesiredSize.Width);
        }
        return new Size(double.IsInfinity(available.Width) ? width : available.Width, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double y = 0;
        foreach (UIElement child in InternalChildren)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            child.Arrange(new Rect(0, y, final.Width, child.DesiredSize.Height));
            y += child.DesiredSize.Height + Spacing;
        }
        return final;
    }
}
