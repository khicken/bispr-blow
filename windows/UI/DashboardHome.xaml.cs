using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace BisprBlow;

public partial class HomeView : UserControl
{
    readonly AppSettings settings = AppSettings.Shared;
    readonly HistoryStore history = HistoryStore.Shared;
    readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromSeconds(2) };

    public HomeView()
    {
        InitializeComponent();
        // Singletons outlive the page, so the page listens only while it is on screen.
        Loaded += (_, _) =>
        {
            history.Entries.CollectionChanged += OnHistory;
            settings.PropertyChanged += OnSettings;
            UpdateChecker.Shared.PropertyChanged += OnUpdateChanged;
            refresh.Start();
            Reload();
        };
        Unloaded += (_, _) =>
        {
            history.Entries.CollectionChanged -= OnHistory;
            settings.PropertyChanged -= OnSettings;
            UpdateChecker.Shared.PropertyChanged -= OnUpdateChanged;
            refresh.Stop();
        };
        // A slow timer: the user comes back from Settings with the switch flipped.
        refresh.Tick += (_, _) => Access.Visibility = Permissions.MicrophoneAllowed ? Visibility.Collapsed : Visibility.Visible;
        Reload();
    }

    static string Greeting => DateTime.Now.Hour switch
    {
        >= 5 and < 12 => "Good morning",
        >= 12 and < 17 => "Good afternoon",
        _ => "Good evening",
    };

    int AverageWpm
    {
        get
        {
            var rates = history.Entries.Where(e => e.DurationSeconds > 1)
                .Select(e => e.Cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length / (e.DurationSeconds / 60)).ToList();
            return rates.Count == 0 ? 0 : (int)rates.Average();
        }
    }

    int StreakDays
    {
        get
        {
            var days = history.Entries.Select(e => HistoryRow.Local(e.Date).Date).ToHashSet();
            var day = DateTime.Today;
            var streak = 0;
            while (days.Contains(day)) { streak++; day = day.AddDays(-1); }
            return streak;
        }
    }

    // Names the user's own binding: the default stops being the answer the moment they rebind it.
    string Subtitle
    {
        get
        {
            if (settings.DictationShortcutName is null) return "Set a dictation shortcut in Settings to get started.";
            var lockHint = settings.Shortcuts(ShortcutAction.PushToTalk).Count == 0 ? "" : " Double-tap to go hands-free.";
            return $"{settings.HoldHint}.{lockHint}";
        }
    }

    void Reload()
    {
        Page.Title = Greeting;
        Page.Subtitle = Subtitle;
        Words.Text = history.TotalWords.ToString("N0");
        Wpm.Text = AverageWpm.ToString("N0");
        Streak.Text = StreakDays.ToString("N0");
        Recent.ItemsSource = history.Entries.Take(8).ToList();
        Empty.Visibility = history.Entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Empty.Content = settings.HoldPhrase is { } phrase ? $"{phrase} and say something." : "Set a dictation shortcut in Settings.";
        Access.Visibility = Permissions.MicrophoneAllowed ? Visibility.Collapsed : Visibility.Visible;
        ShowUpdate();
    }

    void ShowUpdate()
    {
        var latest = UpdateChecker.Shared.Latest;
        Banner.Visibility = latest is null ? Visibility.Collapsed : Visibility.Visible;
        BannerText.Text = $"BisprBlow {latest} is out";
    }

    // The sync and the update check do not run on the UI thread.
    void OnHistory(object? s, NotifyCollectionChangedEventArgs e) => Dispatcher.BeginInvoke(Reload);
    void OnSettings(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Reload);
    void OnUpdateChanged(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(ShowUpdate);

    void OnUpdateClick(object sender, RoutedEventArgs e) => UpdateChecker.Shared.OpenRelease();
    void OnOpenMicrophoneSettings(object sender, RoutedEventArgs e) => Permissions.OpenMicrophoneSettings();
}
