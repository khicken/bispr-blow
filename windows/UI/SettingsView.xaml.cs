using System.ComponentModel;
using System.Windows.Automation;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace BisprBlow;

public partial class SettingsView : UserControl
{
    readonly AppSettings settings = AppSettings.Shared;
    readonly LLMCleaner cleaner = new();
    readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromSeconds(2) };
    IReadOnlyList<(string Id, string Name)> devices = [];
    string micName = "";
    bool refreshing, importing;
    Cleanup shownCleanup;
    CancellationTokenSource? download;
    double? fraction;
    string? failure;

    public SettingsView()
    {
        InitializeComponent();
        shownCleanup = settings.Cleanup;
        Wispr.Visibility = WisprImport.IsInstalled ? Visibility.Visible : Visibility.Collapsed;
        WisprIcon.Source = WisprImport.AppIcon;
        WisprIcon.Visibility = WisprIcon.Source is null ? Visibility.Collapsed : Visibility.Visible;
        Account.Visibility = CloudConfig.Ready ? Visibility.Visible : Visibility.Collapsed;
        ChoiceFast.Tag = Cleanup.Fast.Detail();
        ChoiceAccurate.Tag = Cleanup.Accurate.Detail();
        Loaded += (_, _) => { settings.PropertyChanged += OnSettings; refresh.Start(); Poll(); Reload(); };
        Unloaded += (_, _) => { settings.PropertyChanged -= OnSettings; refresh.Stop(); };
        refresh.Tick += (_, _) => Poll();
        Poll();
        Reload();
    }

    void OnSettings(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        Reload();
        // Load the mode's model and prime the prompt-prefix cache now, so the next dictation isn't
        // the one that waits for it.
        if (shownCleanup == settings.Cleanup) return;
        shownCleanup = settings.Cleanup;
        _ = cleaner.WarmUpAsync();
    });

    // Permission and the default mic's name change outside the app, so they are asked again.
    void Poll()
    {
        Access.Visibility = Permissions.MicrophoneAllowed ? Visibility.Collapsed : Visibility.Visible;
        var name = DefaultMicName();
        var list = AudioRecorder.InputDevices();
        if (name == micName && list.SequenceEqual(devices)) return;
        micName = name;
        devices = list;
        RefreshMic();
    }

    static string DefaultMicName()
    {
        try
        {
            using var enumerator = new NAudio.CoreAudioApi.MMDeviceEnumerator();
            return enumerator.GetDefaultAudioEndpoint(NAudio.CoreAudioApi.DataFlow.Capture, NAudio.CoreAudioApi.Role.Console).FriendlyName;
        }
        catch { return ""; }  // no mic at all
    }

    void Reload()
    {
        ChoiceFast.IsChecked = settings.Cleanup == Cleanup.Fast;
        ChoiceAccurate.IsChecked = settings.Cleanup == Cleanup.Accurate;
        DownloadRow.Visibility = fraction is null ? Visibility.Collapsed : Visibility.Visible;
        DownloadBar.Value = fraction ?? 0;
        DownloadText.Text = $"Downloading Accurate, {(int)((fraction ?? 0) * 100)}%";
        DownloadFailure.Visibility = fraction is null && failure is not null ? Visibility.Visible : Visibility.Collapsed;
        DownloadFailure.Text = failure ?? "";
        DownloadFailure.SetResourceReference(TextBlock.ForegroundProperty, "Bj.InkSubtle");
        RefreshMic();
        RefreshThemes();
    }

    void RefreshMic()
    {
        refreshing = true;
        Mic.Items.Clear();
        Mic.Items.Add(micName.Length == 0 ? "System default" : $"System default ({micName})");
        foreach (var device in devices) Mic.Items.Add(device.Name);
        var index = devices.ToList().FindIndex(d => d.Id == settings.InputDeviceID);
        Mic.SelectedIndex = index + 1;  // not found, or the default, is 0
        refreshing = false;
    }

    void OnMicChanged(object sender, SelectionChangedEventArgs e)
    {
        if (refreshing || Mic.SelectedIndex < 0) return;
        settings.InputDeviceID = Mic.SelectedIndex == 0 ? "" : devices[Mic.SelectedIndex - 1].Id;
    }

    void OnOpenMicrophoneSettings(object sender, RoutedEventArgs e) => Permissions.OpenMicrophoneSettings();

    // ---- Writing

    async void OnChoice(object sender, RoutedEventArgs e)
    {
        var mode = sender == ChoiceAccurate ? Cleanup.Accurate : Cleanup.Fast;
        // Picking Accurate with nothing behind it would select it and go on writing with Fast,
        // silently. Ask, and stay on Fast until the weights land.
        if (mode == Cleanup.Accurate && LLMCleaner.AccurateNeedsModel && download is null)
        {
            Reload();
            if (MessageBox.Show(Window.GetWindow(this), "It's 1.8 GB. Fast stays on until it finishes.", "Download the Accurate model?",
                    MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            await StartDownload();
            return;
        }
        settings.Cleanup = mode;
    }

    async Task StartDownload()
    {
        download = new();
        failure = null;
        fraction = 0;
        Reload();
        try
        {
            await ModelDownloader.DownloadAsync(ModelDownloader.Accurate,
                new Progress<double>(p => { fraction = p; Reload(); }), download.Token);
            settings.Cleanup = Cleanup.Accurate;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { failure = ex.Message; Log.Line($"Accurate download failed: {ex.Message}"); }
        download = null;
        fraction = null;
        Reload();
    }

    void OnStopDownload(object sender, RoutedEventArgs e) => download?.Cancel();

    // ---- Wispr Flow

    // Off the UI thread: every candidate is replayed over Wispr Flow's whole history.
    async void OnImportWispr(object sender, RoutedEventArgs e)
    {
        if (importing) return;
        importing = true;
        WisprButton.IsEnabled = false;
        WisprButton.Content = "Importing…";
        WisprResult.Text = "Your dictionary and corrected names.";
        var vocabulary = settings.Vocabulary;
        var words = await Task.Run(() => WisprImport.LearnedWords(vocabulary));
        var added = words is null ? (int?)null : WisprImport.Add(words, settings).Count;
        WisprResult.Text = added switch
        {
            null => WisprImport.FailureMessage,
            0 => "Nothing new to add",
            1 => "Added 1 word",
            var count => $"Added {count} words",
        };
        WisprButton.Content = "Import";
        WisprButton.IsEnabled = true;
        importing = false;
    }

    // ---- Appearance

    void RefreshThemes()
    {
        Themes.Children.Clear();
        foreach (var appearance in Enum.GetValues<Appearance>())
            Themes.Children.Add(new ThemeSwatch(appearance, settings.Appearance == appearance, () => settings.Appearance = appearance));
    }
}

// A theme, shown as the thing it themes: the window at postage-stamp size (sidebar, nav, cards and the
// pill) drawn entirely from the palette on offer. Every fill comes from the same table the app reads at
// runtime, so a swatch cannot show a look the app will not draw.
sealed class ThemeSwatch : Button
{
    const double W = 156, PreviewH = 96, H = 134;

    public ThemeSwatch(Appearance appearance, bool selected, Action choose)
    {
        Width = W; Height = H; Margin = new(0, 0, 10, 10);
        Cursor = System.Windows.Input.Cursors.Hand;
        FocusVisualStyle = null;
        Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
            "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><ContentPresenter/></ControlTemplate>");
        AutomationProperties.SetName(this, $"{appearance} theme");

        var column = new StackPanel { Width = W, Height = H };
        // System draws both halves. It resolves to Light or Dark, so alone it would be an exact copy of
        // whichever is in force; the pair is also the truer answer.
        var preview = new Grid { Height = PreviewH, ClipToBounds = true };
        if (appearance == Appearance.System)
        {
            preview.Children.Add(MiniWindow(Appearance.Light.PaletteFor()));
            var dark = MiniWindow(Appearance.Dark.PaletteFor());
            dark.Clip = new RectangleGeometry(new Rect(W / 2, 0, W / 2, PreviewH));
            preview.Children.Add(dark);
        }
        else preview.Children.Add(MiniWindow(appearance.PaletteFor()));
        column.Children.Add(preview);

        var label = new DockPanel { Margin = new(11, 9, 11, 9) };
        var tick = new TextBlock { Text = "", Opacity = selected ? 1 : 0, VerticalAlignment = VerticalAlignment.Center };
        tick.SetResourceReference(StyleProperty, "Bj.Icon");
        tick.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Blue");
        tick.FontSize = 11;
        DockPanel.SetDock(tick, Dock.Right);
        var name = new TextBlock { Text = appearance.ToString(), FontWeight = FontWeights.Medium };
        name.SetResourceReference(StyleProperty, "Bj.Caption");
        name.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Ink");
        label.Children.Add(tick);
        label.Children.Add(name);
        column.Children.Add(label);

        var frame = new Border { CornerRadius = new(12), BorderThickness = new(selected ? 2 : 1), Child = column, Background = Brushes.Transparent };
        frame.SetResourceReference(Border.BackgroundProperty, "Bj.Cream");
        frame.SetResourceReference(Border.BorderBrushProperty, selected ? "Bj.Blue" : "Bj.Border");
        // The clip is what rounds the preview's square corners.
        frame.Clip = new RectangleGeometry(new Rect(0, 0, W, H), 12, 12);
        Content = frame;

        RenderTransformOrigin = new(0.5, 0.5);
        RenderTransform = new ScaleTransform();
        Click += (_, _) => choose();
        MouseEnter += (_, _) => Scale(selected ? 1 : 1.015);
        MouseLeave += (_, _) => Scale(1);
    }

    void Scale(double to)
    {
        var scale = (ScaleTransform)RenderTransform;
        var anim = new DoubleAnimation(to, (Duration)FindResource("Bj.Snap")) { EasingFunction = (IEasingFunction)FindResource("Bj.Ease") };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, anim);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, anim);
    }

    static Brush Fill(Color c, double opacity = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)(c.A * opacity), c.R, c.G, c.B));
        brush.Freeze();
        return brush;
    }

    static Border Capsule(Color c, double opacity, double w, double h) =>
        new() { Width = w, Height = h, CornerRadius = new(h / 2), Background = Fill(c, opacity), HorizontalAlignment = HorizontalAlignment.Left };

    // The app, small. Same proportions and the same parts as the real window, including the way a
    // theme with brand imagery puts it at the foot of the sidebar and fades it into the rail.
    static Grid MiniWindow(Palette p)
    {
        var root = new Grid { Width = W, Height = PreviewH };
        root.ColumnDefinitions.Add(new() { Width = new(58) });
        root.ColumnDefinitions.Add(new());

        var side = new Grid { Background = Fill(p.Surface) };
        if (p.SidebarImage is { } image)
        {
            side.Children.Add(new Image
            {
                Source = new BitmapImage(new Uri($"pack://application:,,,/Resources/{image}")), Height = 64, Stretch = Stretch.UniformToFill,
                VerticalAlignment = VerticalAlignment.Bottom,
                OpacityMask = new LinearGradientBrush(Colors.Transparent, Color.FromArgb(140, 0, 0, 0), 90),
            });
        }
        var nav = new StackPanel { Margin = new(5, 11, 5, 0) };
        nav.Children.Add(NavRow(p, true, 26));
        nav.Children.Add(NavRow(p, false, 20));
        nav.Children.Add(NavRow(p, false, 23));
        side.Children.Add(nav);
        side.Children.Add(new System.Windows.Shapes.Rectangle { Width = 1, Fill = Fill(p.Border, 0.55), HorizontalAlignment = HorizontalAlignment.Right });
        root.Children.Add(side);

        var page = new Grid { Background = Fill(p.Cream) };
        Grid.SetColumn(page, 1);
        var stack = new StackPanel { Margin = new(11, 12, 11, 0) };
        var title = Capsule(p.Ink, 0.85, 44, 5);
        title.Margin = new(0, 0, 0, 6);
        stack.Children.Add(title);
        stack.Children.Add(Card(p, 40, true));
        stack.Children.Add(Card(p, 30, false));
        page.Children.Add(stack);
        root.Children.Add(page);

        // The recording pill: the part of the app that lives outside the window and the part a user
        // recognises first, at the size and in the place it actually draws.
        var pill = new Border { Width = 46, Height = 13, CornerRadius = new(6.5), Background = Fill(p.PillBackground), Margin = new(0, 0, 0, 10),
                                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom };
        Grid.SetColumnSpan(pill, 2);
        var waves = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var h in new[] { 4.0, 7, 5 })
        {
            var bar = Capsule(p.PillWave, 1, 1.5, h);
            bar.Margin = new(1, 0, 1, 0);
            waves.Children.Add(bar);
        }
        pill.Child = waves;
        root.Children.Add(pill);
        return root;
    }

    static Border NavRow(Palette p, bool active, double label)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new Border { Width = 4, Height = 4, CornerRadius = new(1), Margin = new(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center,
                                      Background = active ? Fill(p.Blue) : Fill(p.InkTertiary, 0.5) });
        row.Children.Add(Capsule(active ? p.Blue : p.InkTertiary, active ? 1 : 0.4, label, 3));
        return new Border { Child = row, Padding = new(4, 3.5, 4, 3.5), Margin = new(0, 0, 0, 4), CornerRadius = new(4),
                            Background = active ? Fill(p.SurfaceActive) : Brushes.Transparent };
    }

    static Border Card(Palette p, double line, bool accent)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var rule = Capsule(p.Ink, 0.3, line, 3);
        rule.Margin = new(0, 0, 5, 0);
        row.Children.Add(rule);
        if (accent) row.Children.Add(Capsule(p.Blue, 1, 11, 3));
        return new Border { Child = row, Padding = new(6), Margin = new(0, 0, 0, 6), CornerRadius = new(4), Background = Fill(p.TableHeader) };
    }
}
