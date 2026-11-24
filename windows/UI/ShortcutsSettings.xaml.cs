using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace BisprBlow;

// The Shortcuts section of Settings: one row per action, whole row opens the editor. The editor is a
// modal window because recording a binding takes over the keyboard, and a modal is the honest way to
// say so.
public sealed class ShortcutRows : UserControl
{
    readonly AppSettings settings = AppSettings.Shared;
    readonly StackPanel list = new();

    public ShortcutRows()
    {
        Content = list;
        Loaded += (_, _) => { settings.PropertyChanged += OnSettings; Rebuild(); };
        Unloaded += (_, _) => settings.PropertyChanged -= OnSettings;
        Rebuild();
    }

    void OnSettings(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Rebuild);

    void Rebuild()
    {
        list.Children.Clear();
        foreach (var action in Enum.GetValues<ShortcutAction>())
        {
            var bindings = settings.Shortcuts(action);
            var line = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            if (bindings.Count == 0) line.Children.Add(Text("Not set", "Bj.Caption", "Bj.InkSubtle"));
            foreach (var shortcut in bindings) line.Children.Add(KeyCap(shortcut.Display, new(0, 0, 4, 0)));
            line.Children.Add(Icon("", new(4, 0, 0, 0)));  // chevron

            var grid = new Grid();
            grid.Children.Add(Text(action.Title(), "Bj.Body", "Bj.Ink"));
            grid.Children.Add(line);
            var row = new Button { Style = (Style)FindResource("Bj.RowButton"), Content = grid, Padding = new(6, 7, 6, 7), Margin = new(0, 0, 0, 2) };
            var chosen = action;
            row.Click += (_, _) => new ShortcutSheet(chosen) { Owner = Window.GetWindow(this) }.ShowDialog();
            list.Children.Add(row);
        }
    }

    internal static TextBlock Text(string text, string style, string ink)
    {
        var block = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center };
        block.SetResourceReference(StyleProperty, style);
        block.SetResourceReference(TextBlock.ForegroundProperty, ink);
        return block;
    }

    internal static TextBlock Icon(string glyph, Thickness margin)
    {
        var block = new TextBlock { Text = glyph, Margin = margin, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
        block.SetResourceReference(StyleProperty, "Bj.Icon");
        block.SetResourceReference(TextBlock.ForegroundProperty, "Bj.InkSubtle");
        block.FontSize = 11;
        return block;
    }

    // A single key cap: "Ctrl+Alt+D", "Mouse 4".
    internal static ContentControl KeyCap(string text, Thickness margin)
    {
        var cap = new ContentControl { Content = text, Margin = margin, VerticalAlignment = VerticalAlignment.Center };
        cap.SetResourceReference(StyleProperty, "Bj.KeyCap");
        return cap;
    }
}

public partial class ShortcutSheet : Window
{
    readonly ShortcutAction action;
    readonly AppSettings settings = AppSettings.Shared;
    bool armed;
    // The combination currently under the user's fingers, mid-record.
    Shortcut? holding;

    public ShortcutSheet(ShortcutAction action)
    {
        this.action = action;
        InitializeComponent();
        ActionTitle.Text = action.Title();
        Blurb.Text = action.Blurb();
        SourceInitialized += (_, _) => Chrome.Apply(this);
        Closed += (_, _) => ShortcutMonitor.Shared.CancelRecord();
        settings.PropertyChanged += OnSettings;
        Closed += (_, _) => settings.PropertyChanged -= OnSettings;
        Rebuild();
    }

    void OnSettings(object? s, PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(Rebuild);

    void Rebuild()
    {
        var bindings = settings.Shortcuts(action);
        Reset.IsEnabled = !bindings.SequenceEqual(action.Defaults());
        Rows.Children.Clear();
        foreach (var shortcut in bindings)
        {
            var remove = new Button { Style = (Style)FindResource("Bj.LinkButton"), Padding = new(8, 4, 8, 4), ToolTip = "Remove this shortcut", Content = ShortcutRows.Icon("", default) };
            var gone = shortcut;
            remove.Click += (_, _) => settings.Remove(gone, action);
            DockPanel.SetDock(remove, Dock.Right);
            var line = new DockPanel { Height = 30, Margin = new(8, 0, 4, 0), LastChildFill = false };
            line.Children.Add(remove);
            line.Children.Add(ShortcutRows.KeyCap(shortcut.Display, default));
            Rows.Children.Add(line);
        }
        Rows.Children.Add(armed ? ArmedRow() : AddRow(bindings.Count == 0));
    }

    Button AddRow(bool none)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        var plus = ShortcutRows.Icon("", new(0, 0, 7, 0));
        plus.SetResourceReference(TextBlock.ForegroundProperty, "Bj.AccentText");
        var label = ShortcutRows.Text(none ? "Record a shortcut" : "Add another", "Bj.Caption", "Bj.AccentText");
        line.Children.Add(plus);
        line.Children.Add(label);
        var row = new Button { Style = (Style)FindResource("Bj.RowButton"), Content = line, Height = 30, Padding = new(8, 0, 8, 0), VerticalContentAlignment = VerticalAlignment.Center };
        row.Click += (_, _) => Arm();
        return row;
    }

    FrameworkElement ArmedRow()
    {
        var line = new DockPanel { Height = 30, Margin = new(8, 0, 4, 0), LastChildFill = false };
        var cancel = new Button { Style = (Style)FindResource("Bj.LinkButton"), Content = "Cancel", Padding = new(8, 4, 8, 4) };
        cancel.Click += (_, _) => Disarm();
        DockPanel.SetDock(cancel, Dock.Right);
        line.Children.Add(cancel);
        // What is under your fingers right now, drawn in the same cap the saved binding will use, so
        // recording shows the result rather than describing it. It lands when you let go.
        if (holding is { } shortcut)
        {
            line.Children.Add(ShortcutRows.KeyCap(shortcut.Display, new(0, 0, 8, 0)));
            line.Children.Add(ShortcutRows.Text("Release to save", "Bj.Caption", "Bj.AccentText"));
        }
        else
        {
            line.Children.Add(ShortcutRows.Icon("", new(0, 0, 7, 0)));
            var label = ShortcutRows.Text("Listening…", "Bj.Caption", "Bj.AccentText");
            label.FontWeight = FontWeights.Medium;
            line.Children.Add(label);
        }
        return line;
    }

    // The monitor's own hook does the capturing: it already sees every key and mouse button, and
    // while armed it swallows them so nothing else reacts. Its callbacks arrive off the UI thread.
    void Arm()
    {
        armed = true;
        holding = null;
        ShortcutMonitor.Shared.Record(
            captured: shortcut => Dispatcher.BeginInvoke(() =>
            {
                settings.Add(shortcut, action);
                armed = false;
                holding = null;
                Rebuild();
            }),
            preview: shortcut => Dispatcher.BeginInvoke(() => { holding = shortcut; Rebuild(); }));
        Rebuild();
    }

    void Disarm()
    {
        armed = false;
        holding = null;
        ShortcutMonitor.Shared.CancelRecord();
        Rebuild();
    }

    void OnReset(object sender, RoutedEventArgs e) => settings.ResetToDefault(action);
    void OnDone(object sender, RoutedEventArgs e) => Close();
}
