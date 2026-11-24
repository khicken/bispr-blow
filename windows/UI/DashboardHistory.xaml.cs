using System.Collections.Specialized;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace BisprBlow;

public partial class HistoryView : UserControl
{
    readonly HistoryStore history = HistoryStore.Shared;

    public HistoryView()
    {
        InitializeComponent();
        List.ItemsSource = history.Entries;
        Loaded += (_, _) => { history.Entries.CollectionChanged += OnHistory; Reload(); };
        Unloaded += (_, _) => history.Entries.CollectionChanged -= OnHistory;
        Reload();
    }

    void Reload()
    {
        var n = history.Entries.Count;
        Empty.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
        Header.Visibility = n == 0 ? Visibility.Collapsed : Visibility.Visible;
        Empty.Content = $"No dictations yet. {AppSettings.Shared.HoldHint}.";
        Count.Text = n == 1 ? "1 dictation" : $"{n} dictations";
    }

    void OnHistory(object? s, NotifyCollectionChangedEventArgs e) => Dispatcher.BeginInvoke(Reload);

    void OnClear(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(Window.GetWindow(this), "This can't be undone.", "Clear all dictations?",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK)
            history.Clear();
    }
}

// One dictation as a card; the whole card copies on click. Fed by its DataContext (a DictationEntry).
// The template is in Styles.xaml.
public class HistoryRow : Control
{
    public static readonly DependencyProperty AppLabelProperty = Prop<string>(nameof(AppLabel), "");
    public static readonly DependencyProperty StampProperty = Prop<string>(nameof(Stamp), "");
    public static readonly DependencyProperty CleanedProperty = Prop<string>(nameof(Cleaned), "");
    public static readonly DependencyProperty RawProperty = Prop<string>(nameof(Raw), "");
    public static readonly DependencyProperty RawVisibilityProperty = Prop(nameof(RawVisibility), Visibility.Collapsed);
    public static readonly DependencyProperty ShowRawProperty = Prop(nameof(ShowRaw), false);
    public static readonly DependencyProperty IsCopiedProperty = Prop(nameof(IsCopied), false);

    static DependencyProperty Prop<T>(string name, T value) =>
        DependencyProperty.Register(name, typeof(T), typeof(HistoryRow), new(value, name == nameof(ShowRaw) ? (d, _) => ((HistoryRow)d).Apply() : null));

    static HistoryRow() =>
        DefaultStyleKeyProperty.OverrideMetadata(typeof(HistoryRow), new FrameworkPropertyMetadata(typeof(HistoryRow)));

    public HistoryRow() => DataContextChanged += (_, _) => Apply();

    public string AppLabel { get => (string)GetValue(AppLabelProperty); set => SetValue(AppLabelProperty, value); }
    public string Stamp { get => (string)GetValue(StampProperty); set => SetValue(StampProperty, value); }
    public string Cleaned { get => (string)GetValue(CleanedProperty); set => SetValue(CleanedProperty, value); }
    public string Raw { get => (string)GetValue(RawProperty); set => SetValue(RawProperty, value); }
    public Visibility RawVisibility { get => (Visibility)GetValue(RawVisibilityProperty); set => SetValue(RawVisibilityProperty, value); }
    public bool ShowRaw { get => (bool)GetValue(ShowRawProperty); set => SetValue(ShowRawProperty, value); }
    public bool IsCopied { get => (bool)GetValue(IsCopiedProperty); set => SetValue(IsCopiedProperty, value); }

    public static DateTime Local(DateTime date) => date.ToLocalTime();

    // Time today, "Yesterday", else a short date: short and steady, so the row does not reflow.
    static string StampFor(DateTime date)
    {
        var day = Local(date);
        if (day.Date == DateTime.Today) return day.ToString("t", CultureInfo.CurrentCulture);
        if (day.Date == DateTime.Today.AddDays(-1)) return "Yesterday";
        return day.ToString("MMM d", CultureInfo.CurrentCulture);
    }

    void Apply()
    {
        if (DataContext is not DictationEntry entry) return;
        AppLabel = entry.AppName.Length == 0 ? "Unknown app" : entry.AppName;
        Stamp = StampFor(entry.Date);
        Cleaned = entry.Cleaned;
        Raw = entry.Raw;
        RawVisibility = ShowRaw && entry.Raw != entry.Cleaned ? Visibility.Visible : Visibility.Collapsed;
    }

    protected override void OnMouseLeftButtonUp(System.Windows.Input.MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (DataContext is not DictationEntry entry) return;
        try { Clipboard.SetText(entry.Cleaned); } catch { return; }  // the clipboard can be held by another app
        IsCopied = true;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        timer.Tick += (_, _) => { timer.Stop(); IsCopied = false; };
        timer.Start();
    }
}
