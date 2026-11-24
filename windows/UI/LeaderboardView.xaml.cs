using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace BisprBlow;

// Words per person over a period, for the team you are in. Signed out or teamless, it shows the one form
// that fixes that instead of an empty board. Hidden when accounts are not configured.
public partial class LeaderboardView : UserControl
{
    static readonly (string Period, string Label)[] PeriodList =
        [("day", "Today"), ("week", "This week"), ("month", "This month"), ("all", "All time")];

    string period = "week";
    List<LeaderboardRow> rows = [];
    bool loadedOnce;
    string? error;
    int ticket;
    Guid? shownOrg;

    static CloudClient Cloud => CloudClient.Shared;

    public LeaderboardView()
    {
        InitializeComponent();
        if (!CloudConfig.Ready) Visibility = Visibility.Collapsed;
        Loaded += (_, _) =>
        {
            Cloud.PropertyChanged += OnCloudChanged;
            Refresh();
            Reload();
        };
        Unloaded += (_, _) => Cloud.PropertyChanged -= OnCloudChanged;
    }

    void OnCloudChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(CloudClient.Session) or nameof(CloudClient.Org))) return;
        Dispatcher.BeginInvoke(() =>
        {
            if (e.PropertyName == nameof(CloudClient.Session) || Cloud.Org?.Id != shownOrg)
            {
                rows = [];
                loadedOnce = false;
                error = null;
            }
            Refresh();
            Reload();
        });
    }

    async void Reload()
    {
        if (Cloud.Session == null || Cloud.Org is not { } org) return;
        shownOrg = org.Id;
        var mine = ++ticket;
        try
        {
            var next = await Cloud.LeaderboardAsync(period);
            if (mine != ticket) return;
            rows = next;
            error = null;
        }
        catch (Exception e)
        {
            if (mine != ticket) return;
            error = e is CloudError ? e.Message : "Couldn't load the leaderboard.";
        }
        loadedOnce = true;
        Refresh();
    }

    void Retry_Click(object sender, RoutedEventArgs e) => Reload();

    static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    void Refresh()
    {
        var signedIn = Cloud.Session != null;
        var org = Cloud.Org;
        OrgName.Text = signedIn ? org?.Name ?? "" : "";
        Periods.Visibility = Show(signedIn && org != null);
        SignInCard.Visibility = Show(!signedIn);
        TeamCard.Visibility = Show(signedIn && org == null);
        Board.Visibility = Show(signedIn && org != null);
        if (!signedIn || org == null) return;

        BuildPeriods();
        ErrorRow.Visibility = Show(error != null);
        ErrorText.Text = error ?? "";
        var empty = error == null && loadedOnce && rows.Count == 0;
        EmptyHint.Visibility = Show(empty);
        if (empty)
        {
            var when = period switch { "day" => "today", "week" => "this week", "month" => "this month", _ => "yet" };
            EmptyHint.Content = $"Nothing on the board {when}. {AppSettings.Shared.HoldHint}.";
        }
        BuildRows(Cloud.Session!.UserID);
    }

    void BuildPeriods()
    {
        Periods.Children.Clear();
        foreach (var (key, label) in PeriodList)
        {
            var button = new Button
            {
                Content = label,
                Margin = new Thickness(4, 0, 0, 0),
                Style = (Style)FindResource(key == period ? "Bj.PrimaryButton" : "Bj.SecondaryButton"),
            };
            button.Click += (_, _) =>
            {
                if (period == key) return;
                period = key;
                loadedOnce = false;
                Refresh();
                Reload();
            };
            Periods.Children.Add(button);
        }
    }

    void BuildRows(Guid me)
    {
        Rows.Children.Clear();
        var rank = 0;
        foreach (var row in rows)
        {
            rank++;
            var mine = row.UserID == me;
            var line = new Grid { Margin = new Thickness(12, 9, 12, 9) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            line.Children.Add(Text(rank.ToString(CultureInfo.InvariantCulture), "Bj.Caption", 0));

            var circle = new Border { Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            var name = row.DisplayName.Trim();
            var initial = name.Length > 0 ? name[..1].ToUpperInvariant() : "?";
            circle.Width = circle.Height = 28;
            circle.CornerRadius = new CornerRadius(14);
            circle.SetResourceReference(Border.BackgroundProperty, mine ? "Bj.Blue" : "Bj.Border");
            var letter = new TextBlock
            {
                Text = initial, FontWeight = FontWeights.SemiBold, FontSize = 12,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            };
            letter.SetResourceReference(TextBlock.ForegroundProperty, mine ? "Bj.OnAccent" : "Bj.Ink");
            circle.Child = letter;
            Grid.SetColumn(circle, 1);
            line.Children.Add(circle);

            var middle = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var title = new StackPanel { Orientation = Orientation.Horizontal };
            var nameText = new TextBlock { Text = name.Length > 0 ? name : "Teammate", TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = FontWeights.Medium };
            nameText.SetResourceReference(FrameworkElement.StyleProperty, "Bj.Body");
            title.Children.Add(nameText);
            if (mine) title.Children.Add(Text(" (you)", "Bj.Caption", -1));
            if (row.DayStreak > 1) title.Children.Add(Flame());
            middle.Children.Add(title);
            if (row.Wpm is { } wpm && wpm > 0)
                middle.Children.Add(Text($"{Math.Round(wpm):0} words a minute", "Bj.Micro", -1));
            Grid.SetColumn(middle, 2);
            line.Children.Add(middle);

            var count = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            var number = Text(row.Words.ToString("N0", CultureInfo.CurrentCulture), "Bj.Body", -1);
            number.FontWeight = FontWeights.SemiBold;
            count.Children.Add(number);
            var unit = Text(" words", "Bj.Micro", -1);
            unit.VerticalAlignment = VerticalAlignment.Bottom;
            unit.Margin = new Thickness(0, 0, 0, 1);
            count.Children.Add(unit);
            Grid.SetColumn(count, 3);
            line.Children.Add(count);

            var card = new Border { CornerRadius = (CornerRadius)FindResource("Bj.RowRadius"), Margin = new Thickness(0, 0, 0, 6), Child = line };
            card.SetResourceReference(Border.BackgroundProperty, mine ? "Bj.BlueSoft" : "Bj.TableHeader");
            Rows.Children.Add(card);
        }
    }

    TextBlock Text(string text, string style, int column)
    {
        var block = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center };
        block.SetResourceReference(FrameworkElement.StyleProperty, style);
        if (column >= 0) Grid.SetColumn(block, column);
        return block;
    }

    // A day streak of two or more.
    static Path Flame()
    {
        var flame = new Path
        {
            Data = Geometry.Parse("M6,0 C6,3 10,4.5 10,9 A4,4 0 0 1 2,9 C2,7.5 3,6.5 3.5,5.5 C4.5,6.5 5,6.5 5,5 C5,3.5 6,2 6,0 Z"),
            Width = 10, Height = 13, Stretch = Stretch.Uniform,
            Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        flame.SetResourceReference(Shape.FillProperty, "Bj.Red");
        return flame;
    }
}
