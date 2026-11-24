using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace BisprBlow;

// Pushes dictation stats — and, under its own opt-in, their text — to the signed-in account, after
// the fact. Local history is the source of truth: this only reads it, and every push is an upsert
// keyed on the entry's UUID, so retries are free and nothing can duplicate. It wakes when history
// gains an entry (debounced, clear of the release-to-paste path) and on a slow timer for whatever a
// failed push left behind. Nothing touches the network unless signed in with the stats toggle on.
// UI thread only, like everything that touches CloudClient.
public sealed class SyncEngine
{
    public static readonly SyncEngine Shared = new();

    // Which entries have already landed, in its own file next to history.json rather than inside the
    // entries, so `DictationEntry` stays byte-compatible with every history file on disk. Two sets,
    // because text sync can be switched on after years of metric sync. A key missing from the file
    // leaves the default, so an older (or newer) file never resets the sets.
    public sealed class State
    {
        [JsonPropertyName("metrics")] public HashSet<Guid> Metrics { get; set; } = [];
        [JsonPropertyName("texts")] public HashSet<Guid> Texts { get; set; } = [];
        // Dictionary words this PC has put on the server, spelled exactly as sent.
        [JsonPropertyName("words")] public HashSet<string> Words { get; set; } = [];
    }

    static readonly string FilePath = Path.Combine(AppPaths.Support, "sync-state.json");
    State state;
    bool syncing;
    // Bumped whenever what a landed row means changes (org joined, sign-out). A push that started
    // under an older value must not record its rows as synced: they carry the old org_id.
    int generation;
    bool rerun;
    bool syncingWords;
    bool rerunWords;
    Guid? lastOrg;
    DispatcherTimer? historyDebounce, wordsDebounce, slow;

    SyncEngine()
    {
        try { state = File.Exists(FilePath) ? JsonSerializer.Deserialize<State>(File.ReadAllText(FilePath)) ?? new() : new(); }
        catch (Exception e) when (e is IOException or JsonException) { state = new(); }
    }

    static DispatcherTimer Timer(double seconds, Action tick, bool repeats = false)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) =>
        {
            if (!repeats) timer.Stop();
            tick();
        };
        return timer;
    }

    static void Restart(DispatcherTimer timer) => timer.Dispatcher.BeginInvoke(() => { timer.Stop(); timer.Start(); });

    // Wiring only — no network happens here, just subscriptions and a timer.
    public void Start()
    {
        historyDebounce = Timer(5, Kick);
        wordsDebounce = Timer(2, KickWords);
        HistoryStore.Shared.Entries.CollectionChanged += (_, _) => Restart(historyDebounce);
        // Turning a toggle on is the moment the user expects the backlog to move. The current value is
        // checked here too, which is what pushes anything dictated while offline.
        var settings = AppSettings.Shared;
        if (settings.SyncStats || settings.SyncTexts) Kick();
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppSettings.SyncStats) or nameof(AppSettings.SyncTexts)
                && (settings.SyncStats || settings.SyncTexts)) Kick();
            // The dictionary goes to teammates as you edit it, so a burst of typing is one push.
            if (e.PropertyName == nameof(AppSettings.Dictionary)) Restart(wordsDebounce);
        };
        // Sign-in lands here too: it fetches the org straight afterwards.
        CloudClient.Shared.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(CloudClient.Org) || CloudClient.Shared.Org?.Id == lastOrg) return;
            lastOrg = CloudClient.Shared.Org?.Id;
            if (lastOrg != null) KickWords();
        };
        slow = Timer(300, () => { Kick(); KickWords(); }, repeats: true);
        slow.Start();
    }

    // Sync if there is anything to do and the user asked for it; otherwise free.
    public async void Kick()
    {
        if (syncing || !CloudConfig.Ready || !AppSettings.Shared.SyncStats || CloudClient.Shared.Session == null) return;
        syncing = true;
        await Push();
        syncing = false;
        if (rerun)
        {
            rerun = false;
            Kick();
        }
    }

    // Joining a team is the leaderboard opt-in, so rows pushed before the join get restamped
    // with the org — same ids, so this is an update everywhere, never a duplicate.
    // A push already in flight is told to drop its result and a fresh one follows it.
    public void NoteOrgChanged()
    {
        generation++;
        state.Metrics = [];
        state.Words = [];
        Save();
        if (syncing) rerun = true;
        Kick();
        KickWords();
    }

    // Sign-out forgets what was synced. The rows themselves are never touched from here — the
    // worst a stale set could do is make the next account's first sync fail, so it goes.
    public void Reset()
    {
        generation++;
        state = new();
        Save();
    }

    // MARK: - The dictionary

    // Mirrors the local dictionary to the server for teammates to read. Only while signed in and in
    // a team; with nothing changed since the last push it never touches the network.
    public async void KickWords()
    {
        if (!CloudConfig.Ready || CloudClient.Shared.Session == null) return;
        if (syncingWords)
        {
            rerunWords = true;
            return;
        }
        syncingWords = true;
        await PushWords();
        syncingWords = false;
        if (rerunWords)
        {
            rerunWords = false;
            KickWords();
        }
    }

    async Task PushWords()
    {
        var cloud = CloudClient.Shared;
        var local = DictionaryWords.Clean(AppSettings.Shared.Dictionary);
        var (upsert, delete) = DictionaryWords.Plan(local, state.Words);
        if (upsert.Count == 0 && delete.Count == 0) return;
        if (cloud.Org == null) await cloud.RefreshOrgAsync();
        if (cloud.Org == null) return;

        var started = generation;
        try
        {
            // Deletes first: a recased word is a delete of the old spelling and an upsert of the
            // new one, and in that order a case-insensitive key still ends up with the new one.
            foreach (var chunk in delete.Chunk(25)) await cloud.DeleteDictionaryWordsAsync(chunk);
            foreach (var chunk in upsert.Chunk(100)) await cloud.UpsertDictionaryWordsAsync(chunk);
            if (started != generation) return;
            state.Words = [.. local];
            Save();
        }
        catch (Exception e) { Log.Line($"dictionary sync failed: {e.Message}"); }
    }

    // MARK: - The push

    async Task Push()
    {
        var cloud = CloudClient.Shared;
        if (cloud.Session is not { } session) return;
        // The org stamps every row; a member who signed in on a second machine has one on the
        // server that this client has never seen.
        if (cloud.Org == null) await cloud.RefreshOrgAsync();

        var started = generation;
        var entries = HistoryStore.Shared.Entries.ToList();
        var byID = entries.GroupBy(e => e.Id).ToDictionary(g => g.Key, g => g.First());
        try
        {
            foreach (var chunk in Pending(entries.Select(e => e.Id), state.Metrics).Chunk(100))
            {
                var landed = await Deliver(chunk, id => byID.TryGetValue(id, out var e)
                    ? MetricRow(e, session.UserID, cloud.Org?.Id) : null, cloud.UpsertDictationsAsync);
                // The org changed mid-push: these rows carry the old one, so leave them unrecorded.
                if (started != generation) return;
                state.Metrics.UnionWith(landed);
                Save();
            }
            if (AppSettings.Shared.SyncTexts)
            {
                // Texts reference metric rows, so only ids that have landed qualify.
                var eligible = entries.Select(e => e.Id).Where(state.Metrics.Contains);
                foreach (var chunk in Pending(eligible, state.Texts).Chunk(100))
                {
                    var landed = await Deliver(chunk, id => byID.TryGetValue(id, out var e) ? TextRow(e) : null,
                                               cloud.UpsertTextsAsync);
                    if (started != generation) return;
                    state.Texts.UnionWith(landed);
                    Save();
                }
            }
        }
        // Logged, not shown: the next wake retries from exactly where this stopped.
        catch (Exception e) { Log.Line($"sync push failed: {e.Message}"); }
    }

    // Posts one chunk. One row the server refuses must not hold the queue: on a rejection the chunk
    // is halved until the bad row stands alone, and that row is logged and counted as done so
    // everything behind it moves. Anything else (offline, 5xx, signed out) throws for the retry.
    static async Task<List<Guid>> Deliver(Guid[] ids, Func<Guid, Dictionary<string, object>?> build,
                                          Func<List<Dictionary<string, object>>, Task> post)
    {
        try
        {
            await post(ids.Select(build).OfType<Dictionary<string, object>>().ToList());
            return [.. ids];
        }
        catch (CloudError e) when (IsRowRejection(e.Status))
        {
            if (ids.Length == 1)
            {
                Log.Line($"sync skipped a row the server rejects ({e.Status}): {ids[0]}");
                return [.. ids];
            }
            var mid = ids.Length / 2;
            var head = await Deliver(ids[..mid], build, post);
            return [.. head, .. await Deliver(ids[mid..], build, post)];
        }
    }

    // A 4xx that is about the payload. Auth, timeout and rate limits are about the moment, so
    // splitting would only multiply the failures.
    public static bool IsRowRejection(int? status) =>
        status is >= 400 and < 500 and not (401 or 403 or 408 or 429);

    // Postgres text cannot hold NUL, and JSON carries it as \u0000, which the server refuses.
    public static string Sanitized(string text) => text.Replace("\0", "");

    // `duration_seconds` is not null and checked >= 0. NaN or infinity would also make the JSON
    // writer throw, so they become 0.
    public static double FiniteDuration(double seconds) => double.IsFinite(seconds) ? Math.Max(0, seconds) : 0;

    // Entries not yet synced, in history order. Pure so the self-check can exercise it.
    public static List<Guid> Pending(IEnumerable<Guid> ids, ISet<Guid> synced) => ids.Where(id => !synced.Contains(id)).ToList();

    // One `dictations` row: the schema's metric columns and nothing else — the words themselves
    // never travel on this path.
    public static Dictionary<string, object> MetricRow(DictationEntry entry, Guid userID, Guid? orgID)
    {
        var row = new Dictionary<string, object>
        {
            ["id"] = entry.Id.ToString(),
            ["user_id"] = userID.ToString(),
            ["created_at"] = CloudClient.Iso(entry.Date),
            ["word_count"] = entry.Cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length,
            ["duration_seconds"] = FiniteDuration(entry.DurationSeconds),
            ["app_name"] = Sanitized(entry.AppName),
            ["bundle_id"] = Sanitized(entry.BundleID),
            ["provider"] = Sanitized(entry.Provider),
        };
        if (orgID is { } org) row["org_id"] = org.ToString();
        return row;
    }

    public static Dictionary<string, object> TextRow(DictationEntry entry) => new()
    {
        ["dictation_id"] = entry.Id.ToString(),
        ["raw"] = Sanitized(entry.Raw),
        ["cleaned"] = Sanitized(entry.Cleaned),
    };

    void Save()
    {
        // Ids that fell off history's cap can never be re-pushed, so remembering them is bloat.
        var keep = HistoryStore.Shared.Entries.Select(e => e.Id).ToHashSet();
        state.Metrics.IntersectWith(keep);
        state.Texts.IntersectWith(keep);
        try
        {
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(state));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (IOException e) { Log.Line($"sync state save failed: {e.Message}"); }
    }
}
