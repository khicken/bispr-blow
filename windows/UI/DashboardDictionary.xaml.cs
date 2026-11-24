using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace BisprBlow;

// Curated one-click vocabulary packs.
static class VocabPacks
{
    public static readonly (string Name, string[] Terms)[] All =
    [
        ("Dev tools", ["git", "worktree", "GitHub", "VS Code", "Cursor", "Claude Code", "CLI", "npm", "pnpm",
            "Vite", "TypeScript", "JavaScript", "Python", "Swift", "regex", "JSON", "YAML",
            "Markdown", "API", "SDK", "CI/CD", "Dockerfile", "linter", "Prettier", "ESLint",
            "Xcode", "Homebrew", "zsh", "tmux", "Vim"]),
        ("Cloud & infra", ["Kubernetes", "kubectl", "Docker", "Terraform", "AWS", "GCP", "Azure", "Vercel",
            "Cloudflare", "nginx", "PostgreSQL", "Postgres", "Redis", "Supabase", "Prisma",
            "LiveKit", "webhook", "OAuth", "JWT", "gRPC", "WebSocket", "DNS", "CDN", "S3",
            "Lambda", "cron", "Datadog", "Sentry"]),
        ("AI / ML", ["LLM", "Anthropic", "Claude", "OpenAI", "GPT", "Gemini", "Llama", "Ollama",
            "LM Studio", "RAG", "embeddings", "fine-tuning", "inference", "transformer",
            "tokenizer", "prompt engineering", "system prompt", "Whisper", "MCP",
            "agentic", "eval", "Hugging Face", "PyTorch", "CUDA", "quantization"]),
        ("Bluejay stack", ["Bluejay", "Next.js", "Prisma", "Supabase", "LiveKit", "middleware", "Slack",
            "Notion", "Sentry", "Twilio", "Deepgram", "BisprBlow"]),
    ];
}

public partial class DictionaryView : UserControl
{
    // The settings store has no field for this, so it lasts until the app quits.
    static bool introDismissed;

    readonly AppSettings settings = AppSettings.Shared;
    readonly LLMCleaner cleaner = new();
    bool recentFirst, generating, modelReady = true;

    public DictionaryView()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            settings.PropertyChanged += OnSettings;
            CloudClient.Shared.PropertyChanged += OnSettings;
            Theme.ThemeChanged += OnTheme;
            OnTheme();
            Refresh();
            modelReady = cleaner.HasModel();
            UpdateComposer();
        };
        Unloaded += (_, _) =>
        {
            settings.PropertyChanged -= OnSettings;
            CloudClient.Shared.PropertyChanged -= OnSettings;
            Theme.ThemeChanged -= OnTheme;
        };
        Refresh();
    }

    void OnSettings(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Refresh);
    void OnTheme() => Dispatcher.BeginInvoke(() =>
    {
        // A brand render where the theme has one, the gradient where it does not. The scrim keeps
        // white text readable, darkest where the text is.
        var image = settings.Appearance.PaletteFor().PanelImage;
        Scrim.Visibility = image is null ? Visibility.Collapsed : Visibility.Visible;
        if (image is null) Hero.SetResourceReference(Border.BackgroundProperty, "Bj.HeroGradient");
        else Hero.Background = new ImageBrush(new BitmapImage(new Uri($"pack://application:,,,/Resources/{image}"))) { Stretch = Stretch.UniformToFill };
    });

    // Search and sort only exist once the list is long enough to need them.
    bool ListIsLong => settings.Dictionary.Count > 8;

    // Typed text that is one topic rather than a list of words: the only case where "add everything
    // about this" means anything.
    string? Topic
    {
        get
        {
            var trimmed = NewWord.Text.Trim();
            return trimmed.Length < 2 || trimmed.Contains(',') ? null : trimmed;
        }
    }

    // Search narrows, the toggle orders. The setting keeps the order terms were added, so newest
    // first is the reverse.
    List<string> Shown
    {
        get
        {
            var matched = settings.Dictionary.Where(w => Search.Text.Length == 0 ||
                CultureInfo.CurrentCulture.CompareInfo.IndexOf(w, Search.Text, CompareOptions.IgnoreCase) >= 0).ToList();
            if (recentFirst) matched.Reverse();
            else matched.Sort(StringComparer.CurrentCultureIgnoreCase);
            return matched;
        }
    }

    int MissingCount(IEnumerable<string> terms)
    {
        var existing = settings.Dictionary.Select(w => w.ToLowerInvariant()).ToHashSet();
        return terms.Count(t => !existing.Contains(t.ToLowerInvariant()));
    }

    void Refresh()
    {
        var all = settings.Dictionary;
        Page.Subtitle = CloudClient.Shared.Org is null ? "These words stay on this PC." : "Your team can see these words.";

        Intro.Visibility = introDismissed ? Visibility.Collapsed : Visibility.Visible;
        IntroChips.Children.Clear();
        foreach (var word in all.TakeLast(5).Reverse())
        {
            var chip = new Grid { Margin = new(0, 0, 8, 8) };
            var fill = new Border { CornerRadius = new(20), Opacity = 0.16 };
            fill.SetResourceReference(Border.BackgroundProperty, "Bj.OnHero");
            var label = new TextBlock { Text = word, Padding = new(14, 8, 14, 8), Opacity = 0.92, TextTrimming = TextTrimming.CharacterEllipsis };
            label.SetResourceReference(StyleProperty, "Bj.Caption");
            label.SetResourceReference(TextBlock.ForegroundProperty, "Bj.OnHero");
            chip.Children.Add(fill);
            chip.Children.Add(label);
            IntroChips.Children.Add(chip);
        }

        Count.Text = all.Count == 1 ? "1 term" : $"{all.Count} terms";
        Tools.Visibility = ListIsLong ? Visibility.Visible : Visibility.Collapsed;
        Sort.Content = recentFirst ? "Newest" : "A–Z";
        Sort.ToolTip = recentFirst ? "Sort alphabetically" : "Sort newest first";

        var shown = Shown;
        Empty.Visibility = all.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatches.Visibility = all.Count > 0 && shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatches.Text = $"No matches for “{Search.Text}”.";
        ListBox.Visibility = shown.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // Past the threshold there is always more content than fits, so the height is fixed.
        Scroller.Height = ListIsLong ? 340 : double.NaN;
        Rows.Children.Clear();
        for (var i = 0; i < shown.Count; i++)
        {
            var word = shown[i];
            Rows.Children.Add(new TermRow(word, first: i == 0, trailingInset: ListIsLong ? 10 : 0,
                settings.HeardAs.GetValueOrDefault(word.ToLowerInvariant()) ?? [],
                list => SetHeardAs(word, list),
                () => settings.Dictionary = settings.Dictionary.Where(w => w != word).ToList()));
        }

        Packs.Children.Clear();
        foreach (var (name, terms) in VocabPacks.All)
        {
            var missing = MissingCount(terms);
            var chip = new Button
            {
                Style = (Style)Resources["Chip"], Content = missing > 0 ? $"{name} +{missing}" : $"{name} ✓",
                IsEnabled = missing > 0, Margin = new(0, 0, 8, 8),
            };
            chip.SetResourceReference(BackgroundProperty, missing > 0 ? "Bj.BlueSoft" : "Bj.TableHeader");
            chip.SetResourceReference(ForegroundProperty, missing > 0 ? "Bj.AccentText" : "Bj.InkSubtle");
            var pack = terms;
            chip.Click += (_, _) => settings.AddDictionaryWords(pack);
            Packs.Children.Add(chip);
        }
        UpdateComposer();
    }

    void SetHeardAs(string word, List<string> list)
    {
        var next = settings.HeardAs.ToDictionary(p => p.Key, p => p.Value);
        next.Remove(word.ToLowerInvariant());
        settings.HeardAs = next;
        foreach (var heard in list) settings.AddHeardAs(heard, word);
    }

    void UpdateComposer()
    {
        AddButton.IsEnabled = NewWord.Text.Trim().Length > 0;
        var topic = Topic;
        Generate.Visibility = topic is null ? Visibility.Collapsed : Visibility.Visible;
        GenerateText.Text = generating ? "Adding related words…" : $"Add words related to “{topic}”";
        Generate.IsEnabled = !generating && modelReady;
        Generate.Foreground = (Brush)FindResource(generating ? "Bj.InkSubtle" : "Bj.AccentText");
        Generate.ToolTip = modelReady ? "Asks the local model for related terms." : "No local model is available. Download one in Settings.";
    }

    void ShowNote(string? text)
    {
        Note.Text = text ?? "";
        Note.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnDismissIntro(object sender, RoutedEventArgs e)
    {
        introDismissed = true;
        Intro.Visibility = Visibility.Collapsed;
    }

    void OnNewWordChanged(object sender, TextChangedEventArgs e) => UpdateComposer();
    void OnSearchChanged(object sender, TextChangedEventArgs e) => Refresh();

    void OnNewWordKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) OnAdd(sender, e);
        else if (e.Key == Key.Escape) { NewWord.Text = ""; ShowNote(null); }
    }

    // One field for one term or a whole list: commas and newlines both split.
    void OnAdd(object sender, RoutedEventArgs e)
    {
        var before = settings.Dictionary;
        settings.AddDictionaryWords(NewWord.Text.Split([',', '\r', '\n']));
        // Say something only when nothing happened: the term appearing in the list is the
        // confirmation. Compared as lists, not counts: a case-only re-add changes a term without
        // changing the count.
        var changed = !before.SequenceEqual(settings.Dictionary);
        ShowNote(changed ? null : "Already in the dictionary.");
        if (changed) NewWord.Text = "";
    }

    async void OnGenerate(object sender, RoutedEventArgs e)
    {
        if (Topic is not { } topic || generating) return;
        generating = true;
        ShowNote(null);
        UpdateComposer();
        var terms = await cleaner.GenerateTermsAsync(topic);
        var before = settings.Dictionary.Count;
        settings.AddDictionaryWords(terms);
        var added = settings.Dictionary.Count - before;
        ShowNote(added > 0 ? null : terms.Count == 0 ? "No model to generate with. Add words by hand." : $"All terms for “{topic}” are already here.");
        if (added > 0) NewWord.Text = "";
        generating = false;
        UpdateComposer();
    }

    void OnSort(object sender, RoutedEventArgs e) { recentFirst = !recentFirst; Refresh(); }

    void OnClearAll(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(Window.GetWindow(this), "This can't be undone.", "Clear the dictionary?",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK)
            settings.Dictionary = [];
    }

    // Rounds the list's corners over its rows, whose hover fill would otherwise square them off.
    void OnListSized(object sender, SizeChangedEventArgs e) =>
        ListBox.Clip = new RectangleGeometry(new Rect(default, e.NewSize), 12, 12);
}

// One term. Clicking the row opens what it gets misheard as; removal appears on hover. A list of a
// hundred terms should read as words, not as buttons.
sealed class TermRow : Border
{
    readonly string word;
    readonly List<string> heardAs;
    readonly Action<List<string>> onHeardAs;
    readonly TextBlock heard = new();
    readonly TextBox field = new();
    readonly Button remove = new();
    bool editing;

    public TermRow(string word, bool first, double trailingInset, List<string> heardAs, Action<List<string>> onHeardAs, Action onRemove)
    {
        this.word = word;
        this.heardAs = heardAs;
        this.onHeardAs = onHeardAs;
        Background = Brushes.Transparent;  // the whole row is the hit target, padding included
        BorderThickness = new(0, first ? 0 : 1, 0, 0);
        SetResourceReference(BorderBrushProperty, "Bj.Border");
        Cursor = Cursors.Hand;
        ToolTip = "Add what it gets misheard as";

        var row = new DockPanel { MinHeight = 38, Margin = new(14, 0, 8 + trailingInset, 0) };
        remove.Content = new TextBlock { Text = "" };  // trash can: it deletes a saved word, so not an X
        ((TextBlock)remove.Content).SetResourceReference(StyleProperty, "Bj.Icon");
        remove.Width = 30; remove.Height = 28; remove.Opacity = 0; remove.Cursor = Cursors.Hand;
        remove.ToolTip = $"Remove {word}";
        remove.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
            "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>" +
            "<Grid Background='Transparent'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Grid></ControlTemplate>");
        remove.SetResourceReference(Control.ForegroundProperty, "Bj.InkSubtle");
        remove.Click += (_, _) => onRemove();
        DockPanel.SetDock(remove, Dock.Right);
        row.Children.Add(remove);

        var name = new TextBlock { Text = word, VerticalAlignment = VerticalAlignment.Center };
        name.SetResourceReference(StyleProperty, "Bj.Body");
        name.SetResourceReference(TextBlock.ForegroundProperty, "Bj.Ink");
        DockPanel.SetDock(name, Dock.Left);
        row.Children.Add(name);

        heard.Text = heardAs.Count == 0 ? "" : $"heard as {string.Join(", ", heardAs)}";
        heard.Margin = new(8, 0, 8, 0); heard.VerticalAlignment = VerticalAlignment.Center; heard.TextTrimming = TextTrimming.CharacterEllipsis;
        heard.SetResourceReference(StyleProperty, "Bj.Caption");
        heard.SetResourceReference(TextBlock.ForegroundProperty, "Bj.InkSubtle");
        field.Margin = new(8, 0, 8, 0); field.Visibility = Visibility.Collapsed; field.Tag = "Misheard as, comma separated";
        field.ToolTip = "Enter to save, Esc to cancel";
        field.SetResourceReference(StyleProperty, "Bj.TextField");
        field.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Save();
            else if (e.Key == Key.Escape) Stop();
        };
        field.LostKeyboardFocus += (_, _) => { if (editing) Save(); };
        var middle = new Grid();
        middle.Children.Add(heard);
        middle.Children.Add(field);
        row.Children.Add(middle);
        Child = row;
    }

    protected override void OnMouseEnter(MouseEventArgs e) { base.OnMouseEnter(e); Highlight(); }
    protected override void OnMouseLeave(MouseEventArgs e) { base.OnMouseLeave(e); Highlight(); }

    // The row under the pointer is the one about to lose a term, so the fill is full strength.
    void Highlight()
    {
        if (IsMouseOver || editing) SetResourceReference(BackgroundProperty, "Bj.SurfaceActive");
        else Background = Brushes.Transparent;
        remove.Opacity = IsMouseOver ? 1 : 0;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (editing) return;
        editing = true;
        field.Text = string.Join(", ", heardAs);
        field.Visibility = Visibility.Visible;
        heard.Visibility = Visibility.Collapsed;
        Cursor = null;
        ToolTip = null;
        Highlight();
        field.Focus();
        field.CaretIndex = field.Text.Length;
    }

    void Stop()
    {
        editing = false;
        field.Visibility = Visibility.Collapsed;
        heard.Visibility = Visibility.Visible;
        Cursor = Cursors.Hand;
        Highlight();
    }

    void Save()
    {
        var list = field.Text.Split(',').Select(t => t.Trim())
            .Where(t => t.Length > 0 && !string.Equals(t, word, StringComparison.OrdinalIgnoreCase)).ToList();
        Stop();
        onHeardAs(list);
    }
}
