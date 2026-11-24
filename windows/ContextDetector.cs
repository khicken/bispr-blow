using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;

namespace BisprBlow;

public enum AppCategory { Messaging, Coding, Writing, Browser, General }

// BundleID is the process name ("Code", "WindowsTerminal", "chrome"), the nearest thing Windows has.
public record AppContext(string BundleID, string AppName, string WindowTitle, string Draft = "", string FieldLabel = "")
{
    // Text already sitting in the field being dictated into (Draft) steers both the recognizer and
    // cleanup toward the topic and register the user is mid-way through. FieldLabel is what the field
    // calls itself — a placeholder, label or description ("Message #general"), often the only thing a
    // field exposes when empty, which is when the draft has nothing to give.

    static readonly string[] Messaging = ["teams", "ms-teams", "discord", "slack", "whatsapp", "telegram", "signal", "messenger"];
    static readonly string[] Coding =
    [
        "windowsterminal", "powershell", "pwsh", "cmd", "conhost", "wt", "wezterm-gui", "alacritty", "warp", "mintty",
        "code", "code - insiders", "cursor", "windsurf", "devenv", "zed", "sublime_text", "notepad++",
        "idea64", "pycharm64", "webstorm64", "rider64", "clion64", "goland64", "phpstorm64", "rubymine64", "studio64",
    ];
    static readonly string[] Writing = ["outlook", "olk", "winword", "notion", "obsidian", "onenote", "thunderbird", "notepad"];
    static readonly string[] Browsers = ["msedge", "chrome", "firefox", "brave", "arc", "dia", "opera", "vivaldi"];

    public AppCategory Category
    {
        get
        {
            var id = BundleID.ToLowerInvariant();
            var title = WindowTitle.ToLowerInvariant();
            if (Messaging.Contains(id)) return AppCategory.Messaging;
            if (Coding.Contains(id)) return AppCategory.Coding;
            if (title.Contains("claude code") || title.Contains("claude") && id.Contains("terminal")) return AppCategory.Coding;
            if (Writing.Contains(id)) return AppCategory.Writing;
            if (Browsers.Contains(id)) return AppCategory.Browser;
            return AppCategory.General;
        }
    }

    // The words already on screen, handed to the recognizer as bias — the general mechanism behind
    // mishearing. The recognizer picks between near homophones on acoustics plus a general-English
    // model, which has no idea the user is looking at code ("query" → "quarry", "prod" → "proud"),
    // and the right word is usually already in the buffer.
    //
    // Identifiers lead, because they are what a bias list exists for. Plain words follow: in a code
    // buffer the plain lowercase words ARE the domain vocabulary, which a "distinctive shapes only"
    // filter threw away. Only words common in any English are dropped, and the list stays capped,
    // since a long one dilutes every entry.
    public IReadOnlyList<string> DraftTerms
    {
        get
        {
            var seen = new HashSet<string>();
            var identifiers = new List<string>();
            var plain = new List<string>();
            foreach (var token in (FieldLabel + " " + Draft).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                var term = token.Trim(Punctuation);
                if (term.Length < 3 || term.Length > 30 || !term.Any(char.IsLetter) || !seen.Add(term.ToLowerInvariant())) continue;
                if (term[1..].Any(char.IsUpper) || term.Contains('.') || term.Contains('_') || term.Contains('-'))
                    identifiers.Add(term);
                else if (term.Length >= 4 && !CommonWords.Contains(term.ToLowerInvariant()))
                    plain.Add(term);
            }
            var head = identifiers.Take(TermCap).ToList();
            return [.. head, .. plain.Take(TermCap - head.Count)];
        }
    }

    const int TermCap = 50;

    // Punctuation the recognizer or the user may have left around a word; the word itself is what
    // goes in the dictionary.
    internal static readonly char[] Punctuation = ['.', ',', ';', ':', '!', '?', '"', '\'', '(', ')', '[', ']', '{', '}'];

    // Words common in every kind of English, so biasing toward them says nothing about the topic.
    // Only function words and generic verbs: "cache", "query", "branch", "commit" are ordinary
    // English AND domain terms, and dropping them would remove exactly the words this is for.
    internal static readonly HashSet<string> CommonWords =
    [
        "about", "after", "again", "against", "actually", "all", "also", "always", "and", "another",
        "any", "anything", "are", "around", "back", "because", "been", "before", "being", "both",
        "but", "came", "can", "come", "could", "did", "does", "doing", "done", "down", "each",
        "even", "ever", "every", "few", "first", "for", "from", "get", "gets", "getting", "give",
        "going", "gone", "good", "got", "had", "has", "have", "having", "her", "here", "him", "his",
        "how", "into", "its", "itself", "just", "keep", "kind", "know", "last", "least", "less",
        "let", "like", "little", "long", "look", "lot", "made", "make", "makes", "many", "may",
        "maybe", "might", "more", "most", "much", "must", "need", "never", "next", "not", "nothing",
        "now", "off", "once", "one", "only", "onto", "other", "our", "out", "over", "own", "part",
        "put", "quite", "rather", "really", "right", "said", "same", "say", "see", "seen", "shall",
        "she", "should", "since", "some", "something", "still", "such", "sure", "take", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "though", "through", "time", "too", "took", "two", "under",
        "until", "use", "used", "using", "very", "want", "was", "way", "well", "went", "were",
        "what", "when", "where", "whether", "which", "while", "who", "why", "will", "with",
        "without", "would", "yes", "yet", "you", "your",
    ];
}

static class ContextDetector
{
    // Every read here is on the path that opens the microphone, already ~150ms of the user's silence,
    // and UI Automation has no timeout of its own: a stuck app answers when it likes. So each read
    // runs on a worker and a slow app gives back whatever arrived before the budget ran out.
    const int FieldBudgetMs = 250;
    const int TextLimit = 4000;

    // Snapshot of the frontmost app. Capture at recording start — the recording pill is
    // non-activating, so the target app stays frontmost.
    public static AppContext Current()
    {
        var window = ForegroundWindow();
        if (window == IntPtr.Zero) return new AppContext("", "", "");
        var pid = ProcessId(window);
        var (name, description) = ProcessNames(pid);
        var field = Bounded(FocusedField, FieldBudgetMs);
        return new AppContext(name, description, WindowTitle(window), field?.Text ?? "", field?.Label ?? "");
    }

    public static IntPtr ForegroundWindow() => GetForegroundWindow();

    public static int ProcessId(IntPtr window)
    {
        GetWindowThreadProcessId(window, out var pid);
        return (int)pid;
    }

    // The focused element, for anyone who needs to come back to it — the correction watcher reads it
    // after the text lands.
    public static (AutomationElement Element, int Pid)? FocusedElement() =>
        Bounded(() => Focused() is { } element ? (element, element.Current.ProcessId) : ((AutomationElement, int)?)null, FieldBudgetMs);

    static AutomationElement? Focused()
    {
        try { return AutomationElement.FocusedElement; }
        catch (Exception) { return null; }
    }

    // Whole value of the focused text element. Null for a password box: a password must not reach a
    // prompt, a log, or history.
    public static string? FocusedText(AutomationElement element) =>
        Bounded(() => ReadText(element), FieldBudgetMs);

    static string? ReadText(AutomationElement element)
    {
        try
        {
            if (element.Current.IsPassword) return null;
            string? value = null;
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern))
                value = ((ValuePattern)valuePattern).Current.Value;
            if (string.IsNullOrWhiteSpace(value) && element.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern))
                value = ((TextPattern)textPattern).DocumentRange.GetText(200_000);
            var text = value?.Trim();
            if (string.IsNullOrEmpty(text)) return null;
            // Tail rather than head: the words nearest the cursor are the ones being written about.
            return text.Length <= TextLimit ? text : text[^TextLimit..];
        }
        catch (Exception) { return null; }
    }

    // The focused field's text and its own name. Selected text is folded in and leads, because a
    // selection is the user pointing at the words they mean.
    static (string Text, string Label)? FocusedField()
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(120);
        if (Focused() is not { } element || ReadText(element) is not { } text) return null;
        try
        {
            var selection = "";
            if (DateTime.UtcNow < deadline && element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)
                && ((TextPattern)pattern).GetSelection() is { Length: > 0 } ranges
                && ranges[0].GetText(201).Trim() is { Length: > 1 and <= 200 } selected)
                selection = selected;

            var label = "";
            if (DateTime.UtcNow < deadline)
                foreach (var phrase in new[] { element.Current.Name, element.Current.HelpText })
                    if (phrase.Trim() is { Length: > 0 and <= 120 } trimmed) { label = trimmed; break; }
            return (selection.Length == 0 ? text : selection + " " + text, label);
        }
        catch (Exception) { return (text, ""); }
    }

    // Runs a UI Automation read off this thread and gives up on it after `ms`. An element that goes
    // away mid-read throws; that is an empty read, not a failure.
    internal static T? Bounded<T>(Func<T?> read, int ms)
    {
        var task = Task.Run(() =>
        {
            try { return read(); }
            catch (Exception) { return default; }
        });
        return task.Wait(ms) ? task.Result : default;
    }

    // "Code" for code.exe, and what the app calls itself ("Visual Studio Code") when Windows will say.
    // Another user's elevated process refuses to be inspected, so the process name stands in.
    static (string Name, string Description) ProcessNames(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            var description = "";
            try { description = process.MainModule?.FileVersionInfo.FileDescription ?? ""; }
            catch (Exception) { }
            return (process.ProcessName, string.IsNullOrWhiteSpace(description) ? process.ProcessName : description.Trim());
        }
        catch (Exception) { return ("", ""); }
    }

    // What an app is called to the user, for the voice command's "switch to app" choices.
    public static string AppName(int pid) => ProcessNames(pid).Description;

    static string WindowTitle(IntPtr window)
    {
        var title = new StringBuilder(512);
        GetWindowText(window, title, title.Capacity);
        return title.ToString();
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
}
