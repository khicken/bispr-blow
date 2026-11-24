using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace BisprBlow;

// The Team page. Signed out it is the sign-in form; signed in it is the team and its roster, where a
// teammate's dictionary words can be added to mine; with no account at all it is a local list of names
// that get spelled right.
public partial class DashboardTeam : UserControl
{
    static CloudClient Cloud => CloudClient.Shared;
    static AppSettings Settings => AppSettings.Shared;

    bool rosterLoaded, rosterFailed;
    Guid? rosterFor;
    int rosterTicket;

    // One member's words open at a time.
    Guid? openMember;
    List<string>? words;
    bool wordsLoading, wordsFailed;
    readonly HashSet<string> selected = [];
    int wordsTicket;

    public DashboardTeam()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Cloud.PropertyChanged += OnCloudChanged;
            Settings.PropertyChanged += OnSettingsChanged;
            Refresh();
            LoadRoster();
        };
        Unloaded += (_, _) =>
        {
            Cloud.PropertyChanged -= OnCloudChanged;
            Settings.PropertyChanged -= OnSettingsChanged;
        };
        NameField.KeyDown += (_, e) => Enter(e);
        RoleField.KeyDown += (_, e) => Enter(e);
    }

    void Enter(KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        AddLocal_Click(null!, null!);
    }

    void OnCloudChanged(object? sender, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        if (e.PropertyName is nameof(CloudClient.Session) or nameof(CloudClient.Org))
        {
            if (Cloud.Org?.Id != rosterFor)
            {
                rosterLoaded = rosterFailed = false;
                openMember = null;
            }
            LoadRoster();
        }
        Refresh();
    });

    void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppSettings.TeamMembers) or nameof(AppSettings.Dictionary))
            Dispatcher.BeginInvoke(Refresh);
    }

    async void LoadRoster()
    {
        if (!CloudConfig.Ready || Cloud.Session == null || Cloud.Org is not { } org) return;
        if (rosterFor == org.Id && rosterLoaded) return;
        rosterFor = org.Id;
        var mine = ++rosterTicket;
        try
        {
            await Cloud.RefreshRosterAsync();
            if (mine != rosterTicket) return;
            rosterFailed = false;
        }
        catch (Exception e)
        {
            Log.Line($"roster load failed: {e.Message}");
            if (mine != rosterTicket) return;
            rosterFailed = true;
        }
        rosterLoaded = true;
        Refresh();
    }

    void RetryRoster_Click(object sender, RoutedEventArgs e)
    {
        rosterLoaded = rosterFailed = false;
        rosterFor = null;
        Refresh();
        LoadRoster();
    }

    static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    void Refresh()
    {
        var cloud = CloudConfig.Ready;
        var signedIn = cloud && Cloud.Session != null;
        var org = signedIn ? Cloud.Org : null;

        SignInCard.Visibility = Show(cloud && !signedIn);
        TeamCard.Visibility = Show(signedIn);
        RosterSection.Visibility = Show(org != null);
        LocalSection.Visibility = Show(!signedIn);
        Page.Subtitle = !cloud ? "Names you add here get spelled right."
            : !signedIn ? "Sign in to join your team."
            : org != null ? "Your teammates and the words they've added."
            : "Names you add here get spelled right.";

        if (org != null) BuildRoster();
        if (!signedIn) BuildLocal();
    }

    // MARK: Local names

    void AddLocal_Click(object sender, RoutedEventArgs e)
    {
        var name = NameField.Text.Trim();
        if (name.Length == 0) return;
        Settings.TeamMembers = [.. Settings.TeamMembers, new TeamMember(name, RoleField.Text.Trim())];
        NameField.Text = "";
        RoleField.Text = "";
        NameField.Focus();
    }

    void BuildLocal()
    {
        LocalRows.Children.Clear();
        var members = Settings.TeamMembers;
        LocalHint.Visibility = Show(members.Count == 0);
        foreach (var member in members)
        {
            var grid = new Grid { Margin = new Thickness(12, 8, 8, 8) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var circle = new Border { Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            Initial(circle, member.Name, 28);
            grid.Children.Add(circle);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(Body(member.Name, medium: true));
            if (member.Role.Length > 0) text.Children.Add(Label(member.Role, "Bj.Micro"));
            Grid.SetColumn(text, 1);
            grid.Children.Add(text);

            var trash = new Button
            {
                Content = new TextBlock { Text = "", FontSize = 13 },
                ToolTip = "Remove",
                Padding = new Thickness(8, 6, 8, 6),
                Opacity = 0,
            };
            trash.SetResourceReference(FrameworkElement.StyleProperty, "Bj.LinkButton");
            ((TextBlock)trash.Content).SetResourceReference(FrameworkElement.StyleProperty, "Bj.Icon");
            var id = member.Id;
            trash.Click += (_, _) => Settings.TeamMembers = [.. Settings.TeamMembers.Where(m => m.Id != id)];
            Grid.SetColumn(trash, 2);
            grid.Children.Add(trash);

            var row = new Border { CornerRadius = (CornerRadius)FindResource("Bj.RowRadius"), Margin = new Thickness(0, 0, 0, 6), Child = grid };
            row.SetResourceReference(Border.BackgroundProperty, "Bj.TableHeader");
            row.MouseEnter += (_, _) => trash.Opacity = 1;
            row.MouseLeave += (_, _) => trash.Opacity = 0;
            LocalRows.Children.Add(row);
        }
    }

    // MARK: Roster

    void BuildRoster()
    {
        RosterRows.Children.Clear();
        var roster = Cloud.Roster;
        RosterError.Visibility = Show(rosterFailed);
        var hint = !rosterLoaded && !rosterFailed ? "Loading members" : rosterLoaded && !rosterFailed && roster.Count == 0 ? "No members yet" : null;
        RosterHint.Visibility = Show(hint != null);
        if (hint != null) RosterHint.Content = hint;

        var me = Cloud.Session?.UserID;
        foreach (var member in roster)
        {
            var panel = new StackPanel();
            panel.Children.Add(MemberHeader(member, member.UserID != me));
            if (openMember == member.UserID) panel.Children.Add(WordsPanel());
            var card = new Border { CornerRadius = (CornerRadius)FindResource("Bj.RowRadius"), Margin = new Thickness(0, 0, 0, 6), Child = panel };
            card.SetResourceReference(Border.BackgroundProperty, "Bj.TableHeader");
            RosterRows.Children.Add(card);
        }
    }

    UIElement MemberHeader(OrgMember member, bool others)
    {
        var grid = new Grid { Margin = new Thickness(12, 9, 8, 9) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var circle = new Border { Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        Initial(circle, member.DisplayName, 28);
        grid.Children.Add(circle);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(Body(member.DisplayName, medium: true));
        if (member.IsOwner)
        {
            var pill = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            pill.SetResourceReference(Border.BackgroundProperty, "Bj.BlueSoft");
            var owner = Label("Owner", "Bj.Micro");
            owner.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Blue");
            pill.Child = owner;
            title.Children.Add(pill);
        }
        text.Children.Add(title);
        if (member.Email is { Length: > 0 } email) text.Children.Add(Label(email, "Bj.Micro"));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        if (others)
        {
            var open = openMember == member.UserID;
            var button = new Button { Content = open ? "Hide words" : "Their words" };
            button.SetResourceReference(FrameworkElement.StyleProperty, "Bj.LinkButton");
            button.Click += (_, _) => ToggleWords(member);
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }
        return grid;
    }

    async void ToggleWords(OrgMember member)
    {
        if (openMember == member.UserID)
        {
            openMember = null;
            Refresh();
            return;
        }
        openMember = member.UserID;
        words = null;
        wordsFailed = false;
        wordsLoading = true;
        selected.Clear();
        Refresh();
        await LoadWords(member.UserID);
    }

    async Task LoadWords(Guid user)
    {
        var mine = ++wordsTicket;
        try
        {
            var loaded = DictionaryWords.Clean(await Cloud.DictionaryWordsAsync(user));
            if (mine != wordsTicket) return;
            words = loaded;
            wordsFailed = false;
        }
        catch (Exception e)
        {
            Log.Line($"teammate words failed: {e.Message}");
            if (mine != wordsTicket) return;
            wordsFailed = true;
        }
        wordsLoading = false;
        Refresh();
    }

    UIElement WordsPanel()
    {
        var panel = new StackPanel { Margin = new Thickness(12, 0, 12, 12) };
        if (wordsLoading)
        {
            panel.Children.Add(Label("Loading words", "Bj.Micro"));
            return panel;
        }
        if (wordsFailed)
        {
            var failed = new StackPanel { Orientation = Orientation.Horizontal };
            var text = Label("Couldn't load their words.", "Bj.Micro");
            text.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Red");
            failed.Children.Add(text);
            var retry = new Button { Content = "Try again" };
            retry.SetResourceReference(FrameworkElement.StyleProperty, "Bj.LinkButton");
            var user = openMember!.Value;
            retry.Click += async (_, _) =>
            {
                wordsFailed = false;
                wordsLoading = true;
                Refresh();
                await LoadWords(user);
            };
            failed.Children.Add(retry);
            panel.Children.Add(failed);
            return panel;
        }
        var theirs = words ?? [];
        if (theirs.Count == 0)
        {
            panel.Children.Add(Label("No words yet", "Bj.Micro"));
            return panel;
        }

        var mine = Settings.Dictionary.Select(w => w.ToLowerInvariant()).ToHashSet();
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        foreach (var word in theirs)
        {
            var have = mine.Contains(word.ToLowerInvariant());
            var on = selected.Contains(word);
            var chip = new Button { Content = word, Margin = new Thickness(0, 0, 6, 6), IsEnabled = !have };
            chip.SetResourceReference(FrameworkElement.StyleProperty, on ? "Bj.PrimaryButton" : "Bj.SecondaryButton");
            if (have)
            {
                // A disabled button shows no tooltip unless the service is on.
                ToolTipService.SetShowOnDisabled(chip, true);
                chip.ToolTip = "Already in your dictionary";
            }
            chip.Click += (_, _) =>
            {
                if (!selected.Remove(word)) selected.Add(word);
                Refresh();
            };
            wrap.Children.Add(chip);
        }
        panel.Children.Add(wrap);

        var addable = DictionaryWords.Importable(theirs, Settings.Dictionary);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var chosen = theirs.Where(selected.Contains).ToList();
        var addSelected = new Button { Content = "Add selected", IsEnabled = chosen.Count > 0, Margin = new Thickness(0, 0, 8, 0) };
        addSelected.SetResourceReference(FrameworkElement.StyleProperty, "Bj.PrimaryButton");
        addSelected.Click += (_, _) =>
        {
            Settings.AddDictionaryWords(chosen);
            selected.Clear();
            Refresh();
        };
        actions.Children.Add(addSelected);
        if (addable.Count > 0)
        {
            var addAll = new Button { Content = $"Add all {addable.Count}" };
            addAll.SetResourceReference(FrameworkElement.StyleProperty, "Bj.SecondaryButton");
            addAll.Click += (_, _) =>
            {
                Settings.AddDictionaryWords(addable);
                selected.Clear();
                Refresh();
            };
            actions.Children.Add(addAll);
        }
        panel.Children.Add(actions);
        return panel;
    }

    // MARK: Bits

    static void Initial(Border border, string name, double size)
    {
        var trimmed = name.Trim();
        border.Width = border.Height = size;
        border.CornerRadius = new CornerRadius(size / 2);
        border.SetResourceReference(Border.BackgroundProperty, "Bj.BlueSoft");
        var letter = new TextBlock
        {
            Text = trimmed.Length > 0 ? trimmed[..1].ToUpperInvariant() : "?",
            FontWeight = FontWeights.SemiBold, FontSize = size * 0.42,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        letter.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Blue");
        letter.SetResourceReference(TextBlock.FontFamilyProperty, "Bj.Font");
        border.Child = letter;
    }

    static TextBlock Label(string text, string style)
    {
        var block = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis };
        block.SetResourceReference(FrameworkElement.StyleProperty, style);
        return block;
    }

    static TextBlock Body(string text, bool medium)
    {
        var block = Label(text, "Bj.Body");
        if (medium) block.FontWeight = FontWeights.Medium;
        return block;
    }
}
