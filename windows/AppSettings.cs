using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Win32;

namespace BisprBlow;

public record TeamMember(Guid Id, string Name, string Role)
{
    public TeamMember(string name, string role) : this(Guid.NewGuid(), name, role) { }
}

// The only thing the user gets to say about cleanup: how much of the pause after they let go it may
// spend. Which model runs is something the app works out.
public enum Cleanup { Fast, Accurate }

public static class CleanupInfo
{
    // What you get, on the row next to the name. The names already say which is quicker; what a user
    // cannot guess is which of their dictations each one suits.
    public static string Detail(this Cleanup c) =>
        c == Cleanup.Fast ? "Best for a sentence or two" : "Best for long, rambling dictations";
}

// JSON-backed settings in %APPDATA%\BisprBlow\settings.json, the Windows stand-in for the Mac's
// defaults suite. Every setter writes the file and raises PropertyChanged, so views bind straight to
// these properties. Lists are replaced, never mutated in place, so a change always notifies.
public sealed class AppSettings : INotifyPropertyChanged
{
    // What is on disk. Kept apart from the class so loading never runs a setter's side effects.
    sealed class Stored
    {
        public Cleanup Cleanup { get; set; } = Cleanup.Fast;
        public string InputDeviceID { get; set; } = "";
        public List<string> Dictionary { get; set; } = [];
        public Dictionary<string, List<string>> HeardAs { get; set; } = [];
        public List<TeamMember> TeamMembers { get; set; } = [];
        public List<string> RosterNames { get; set; } = [];
        public bool SoundsEnabled { get; set; } = true;
        public bool AlwaysShowPill { get; set; } = true;
        public bool LowercaseSentences { get; set; }
        public bool EndWithPeriod { get; set; }
        public bool RestoreMicVolume { get; set; }
        public bool VoiceCommands { get; set; }
        public bool CheckForUpdates { get; set; } = true;
        public string Appearance { get; set; } = "System";
        public bool SyncStats { get; set; }
        public bool SyncTexts { get; set; }
        public string CloudURL { get; set; } = "";
        public string CloudAnonKey { get; set; } = "";
        public string LastMicName { get; set; } = "";
        public string? PillAnchor { get; set; }
        public Dictionary<string, List<Shortcut>>? Bindings { get; set; }
    }

    static readonly string FilePath = Path.Combine(AppPaths.Support, "settings.json");
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() },
    };

    // After FilePath and Json: static initialisers run in order, and the constructor reads both.
    public static readonly AppSettings Shared = new();

    readonly Stored s;

    AppSettings()
    {
        try { s = File.Exists(FilePath) ? JsonSerializer.Deserialize<Stored>(File.ReadAllText(FilePath), Json) ?? new() : new(); }
        catch (Exception e)
        {
            Log.Line($"settings load failed: {e.Message}");
            s = new();
        }
        s.Bindings ??= Enum.GetValues<ShortcutAction>().ToDictionary(a => a.Key(), a => a.Defaults().ToList());
        appearance = AppearanceFor(s.Appearance);
        systemIsDark = ReadSystemIsDark();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    void Changed([CallerMemberName] string name = "")
    {
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    void Save()
    {
        try
        {
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(s, Json));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception e) { Log.Line($"settings save failed: {e.Message}"); }
    }

    public Cleanup Cleanup { get => s.Cleanup; set { s.Cleanup = value; Changed(); } }

    // WASAPI endpoint id of the chosen mic; empty follows the system default input.
    public string InputDeviceID { get => s.InputDeviceID; set { s.InputDeviceID = value; Changed(); } }

    // Custom vocabulary — names and jargon the recognizer mishears. Removing a term drops its heard-as.
    public IReadOnlyList<string> Dictionary
    {
        get => s.Dictionary;
        set
        {
            s.Dictionary = [.. value];
            var terms = value.Select(t => t.ToLowerInvariant()).ToHashSet();
            if (s.HeardAs.Keys.Any(k => !terms.Contains(k)))
                HeardAs = s.HeardAs.Where(p => terms.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value);
            Changed();
        }
    }

    // What a dictionary term gets misheard as, keyed by the term lowercased. Typed on the Dictionary
    // page; the respeller treats each as that term even when it is a real English word.
    public IReadOnlyDictionary<string, List<string>> HeardAs
    {
        get => s.HeardAs;
        set { s.HeardAs = value.ToDictionary(p => p.Key, p => p.Value.ToList()); Changed(); }
    }

    public IReadOnlyList<TeamMember> TeamMembers { get => s.TeamMembers; set { s.TeamMembers = [.. value]; Changed(); } }

    // Display names from the cloud team roster. Kept apart from TeamMembers so a sync never rewrites
    // the hand-typed list, and stored so the names still count before the roster loads at launch.
    public IReadOnlyList<string> RosterNames { get => s.RosterNames; set { s.RosterNames = [.. value]; Changed(); } }

    // A sound when the mic opens and one when the text lands.
    public bool SoundsEnabled { get => s.SoundsEnabled; set { s.SoundsEnabled = value; Changed(); } }

    // Keep the pill on screen while idle. Off, it only appears once you start dictating.
    public bool AlwaysShowPill { get => s.AlwaysShowPill; set { s.AlwaysShowPill = value; Changed(); } }

    // Start with Windows. The real state is the Run key, so this reads it back: a user can turn it off
    // in Task Manager's Startup apps and never touch us.
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public bool LaunchAtLogin
    {
        get => Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue("BisprBlow") is string;
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("BisprBlow", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("BisprBlow", throwOnMissingValue: false);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LaunchAtLogin)));
        }
    }

    // Post-passes on what lands at the cursor, so they hold on the rule-based path too.
    public bool LowercaseSentences { get => s.LowercaseSentences; set { s.LowercaseSentences = value; Changed(); } }
    public bool EndWithPeriod { get => s.EndWithPeriod; set { s.EndWithPeriod = value; Changed(); } }

    // Raise the input volume back to a healthy level before each dictation. Off by default: it writes
    // a system setting, so the user opts in rather than discovers it.
    public bool RestoreMicVolume { get => s.RestoreMicVolume; set { s.RestoreMicVolume = value; Changed(); } }

    // Off by default: a voice command sends the front app's on-screen labels to TypeSafe.
    public bool VoiceCommands { get => s.VoiceCommands; set { s.VoiceCommands = value; Changed(); } }

    // One request to api.github.com at launch. Off, nothing is asked and nothing is sent.
    public bool CheckForUpdates { get => s.CheckForUpdates; set { s.CheckForUpdates = value; Changed(); } }

    // Which look the app draws in; the only stored piece of a theme.
    Appearance appearance;
    public Appearance Appearance
    {
        get => appearance;
        set
        {
            appearance = value;
            s.Appearance = value.ToString();
            Changed();
            Theme.Apply();
        }
    }

    // Whether Windows apps are in dark mode. App keeps this current from UserPreferenceChanged.
    bool systemIsDark;
    public bool SystemIsDark
    {
        get => systemIsDark;
        set
        {
            if (systemIsDark == value) return;
            systemIsDark = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SystemIsDark)));
            if (appearance == Appearance.System) Theme.Apply();
        }
    }

    public static bool ReadSystemIsDark() =>
        Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
            ?.GetValue("AppsUseLightTheme") is 0;

    // Back up dictation stats (counts and timings, never text) to the signed-in account. Off by
    // default: nothing leaves the machine unless asked. Texts are their own opt-in.
    public bool SyncStats { get => s.SyncStats; set { s.SyncStats = value; Changed(); } }
    public bool SyncTexts { get => s.SyncTexts; set { s.SyncTexts = value; Changed(); } }

    // An override for the compiled-in cloud project. Empty means "use CloudConfig", not off.
    public string CloudURL => s.CloudURL;
    public string CloudAnonKey => s.CloudAnonKey;

    // Device name the pill last flashed, so it flashes only when the mic changed.
    public string LastMicName { get => s.LastMicName; set { s.LastMicName = value; Save(); } }

    // Where the pill sits; owned by PillPlacement, stored as its anchor's name.
    public string? PillAnchor { get => s.PillAnchor; set { s.PillAnchor = value; Changed(); } }

    // ---- Shortcuts

    public IReadOnlyDictionary<string, List<Shortcut>> Bindings
    {
        get => s.Bindings!;
        set
        {
            s.Bindings = value.ToDictionary(p => p.Key, p => p.Value.ToList());
            Changed();
            ShortcutMonitor.Shared.Reload();
        }
    }

    public IReadOnlyList<Shortcut> Shortcuts(ShortcutAction action) =>
        Bindings.TryGetValue(action.Key(), out var list) ? list : [];

    // Every binding the monitor has to watch for.
    public IEnumerable<(ShortcutAction Action, Shortcut Shortcut)> AllBindings =>
        Enum.GetValues<ShortcutAction>().SelectMany(a => Shortcuts(a).Select(s => (a, s)));

    public void Add(Shortcut shortcut, ShortcutAction action) => Bindings = Adding(shortcut, action, Bindings);

    public void Remove(Shortcut shortcut, ShortcutAction action)
    {
        var next = Bindings.ToDictionary(p => p.Key, p => p.Value);
        next[action.Key()] = Shortcuts(action).Where(s => s != shortcut).ToList();
        Bindings = next;
    }

    public void ResetToDefault(ShortcutAction action)
    {
        var next = Bindings.ToDictionary(p => p.Key, p => p.Value.Where(s => !action.Defaults().Contains(s)).ToList());
        next[action.Key()] = [.. action.Defaults()];
        Bindings = next;
    }

    // Pure so the self-check can exercise it. Adding a binding steals it from every other action: two
    // actions on one key means only the first one ever fires, silently.
    public static Dictionary<string, List<Shortcut>> Adding(Shortcut shortcut, ShortcutAction action,
                                                            IReadOnlyDictionary<string, List<Shortcut>> bindings)
    {
        var next = bindings.ToDictionary(p => p.Key, p => p.Value.Where(s => s != shortcut).ToList());
        if (!next.TryGetValue(action.Key(), out var list)) next[action.Key()] = list = [];
        list.Add(shortcut);
        return next;
    }

    // Pure so the self-check can exercise it: an unknown stored name lands on System.
    public static Appearance AppearanceFor(string? stored) =>
        Enum.TryParse<Appearance>(stored, out var a) ? a : stored == "Bluejay World" ? Appearance.World : Appearance.System;

    // Display name of the binding that starts a dictation, for user-facing copy.
    public string? DictationShortcutName =>
        (Shortcuts(ShortcutAction.PushToTalk).FirstOrDefault()
         ?? Shortcuts(ShortcutAction.HandsFree).FirstOrDefault()
         ?? Shortcuts(ShortcutAction.PressEnter).FirstOrDefault())?.Display;

    // "Hold Ctrl+Win" or "Press Mouse 4" — the verb follows the kind of binding. Never write user
    // copy that names a key; read this or HoldHint.
    public string? HoldPhrase => DictationShortcutName is { } name
        ? (Shortcuts(ShortcutAction.PushToTalk).Count == 0 ? $"Press {name}" : $"Hold {name}")
        : null;

    public string HoldHint => HoldPhrase is { } p ? $"{p} to dictate" : "Set a dictation shortcut in Settings";

    // Built-in terms, merged under the user's dictionary and never shown.
    public static readonly string[] BuiltInWords =
        ["Bispr Blow", "BisprBlow", "Bluejay", "Claude", "Anthropic", "ChatGPT", "OpenAI", "GitHub", "Supabase"];

    // Terms cleanup corrects toward: dictionary, team names, roster, built-ins, so the user's casing wins.
    public IReadOnlyList<string> Vocabulary =>
        MergedVocabulary(Dictionary, TeamMembers.Select(m => m.Name), RosterNames, BuiltInWords);

    // Groups in priority order, trimmed and unique ignoring case; the first spelling wins.
    public static List<string> MergedVocabulary(params IEnumerable<string>[] groups)
    {
        var seen = new HashSet<string>();
        return groups.SelectMany(g => g).Select(t => t.Trim())
            .Where(t => t.Length > 0 && seen.Add(t.ToLowerInvariant())).ToList();
    }

    // Whether `heard` can be recorded as a mishear of `term`: the term is in the dictionary, and
    // `heard` is not empty, not already listed, and not itself a term — an alias that is another
    // term lets the respeller swap one right word for another.
    public bool CanAddHeardAs(string heard, string term)
    {
        var spoken = heard.Trim().ToLowerInvariant();
        var terms = Vocabulary.Select(t => t.ToLowerInvariant()).ToHashSet();
        return Dictionary.Any(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase))
               && spoken.Length > 0 && !terms.Contains(spoken)
               && !(HeardAs.GetValueOrDefault(term.ToLowerInvariant()) ?? []).Any(h => h.ToLowerInvariant() == spoken);
    }

    public void AddHeardAs(string heard, string term)
    {
        if (!CanAddHeardAs(heard, term)) return;
        var next = HeardAs.ToDictionary(p => p.Key, p => p.Value.ToList());
        var key = term.ToLowerInvariant();
        next[key] = [.. next.GetValueOrDefault(key) ?? [], heard.Trim()];
        HeardAs = next;
    }

    public void AddDictionaryWords(IEnumerable<string> words)
    {
        var next = Dictionary.ToList();
        foreach (var word in words.Select(w => w.Trim()).Where(w => w.Length > 0))
        {
            // Re-adding a stored word with different casing is the user fixing the casing, not a duplicate.
            var existing = next.FindIndex(t => t.ToLowerInvariant() == word.ToLowerInvariant());
            if (existing >= 0) next[existing] = word;
            else next.Add(word);
        }
        Dictionary = next;
    }
}
