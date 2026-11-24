using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;

namespace BisprBlow;

// `BundleID` holds the process name on Windows ("Code", "WindowsTerminal"): it is what the category
// tables match on, and keeping the Mac's field name keeps the history file the same shape on both.
public record DictationEntry(
    Guid Id,
    DateTime Date,
    string Raw,
    string Cleaned,
    string AppName,
    string BundleID,
    string Provider,
    double DurationSeconds);

// JSON-persisted dictation history (most recent first, capped). Same file format as the Mac:
// camelCase keys and ISO-8601 dates, so a history.json copied across reads on either.
public sealed class HistoryStore
{
    public static readonly HistoryStore Shared = new();
    const int Cap = 500;

    public ObservableCollection<DictationEntry> Entries { get; } = [];

    static readonly string FilePath = Path.Combine(AppPaths.Support, "history.json");
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = false };

    HistoryStore()
    {
        try
        {
            if (File.Exists(FilePath) &&
                JsonSerializer.Deserialize<List<DictationEntry>>(File.ReadAllText(FilePath), Json) is { } saved)
                foreach (var entry in saved) Entries.Add(entry);
        }
        // A history that will not load is said out loud: an empty one looks exactly like a new
        // install, which is how the Mac once lost 432 dictations without anyone noticing.
        catch (Exception e) { Log.Line($"history load failed: {e.Message}"); }
    }

    public int TotalWords => Entries.Sum(e => e.Cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length);

    public void Add(DictationEntry entry)
    {
        Entries.Insert(0, entry);
        while (Entries.Count > Cap) Entries.RemoveAt(Entries.Count - 1);
        Persist();
    }

    public void Clear()
    {
        Entries.Clear();
        Persist();
    }

    void Persist()
    {
        try
        {
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Entries, Json));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (IOException e) { Log.Line($"history save failed: {e.Message}"); }
    }
}
