using System.Text;
using System.Globalization;

namespace BisprBlow;

// Cleans raw dictation via a local LLM, with a deterministic rule-based fallback so dictation
// always produces output even with no model available. `resolved` is written by the launch warm-up
// and by the first dictation; it is one reference, replaced whole, so the two cannot tear it. The
// Mac's HTTP "local server" endpoint is not ported: nothing ever started one.
public partial class LLMCleaner
{
    // Provider name stamped on history entries for a model-cleaned dictation.
    const string OnDevice = "On-device";

    record Resolved(string Model, Cleanup Cleanup);

    readonly AppSettings settings = AppSettings.Shared;
    // Resolved once per launch, re-resolved when the mode changes or the model fails.
    Resolved? resolved;
    // What the cached prompt sequence holds, so `PrepareAsync` can re-prime the one a dictation used.
    bool lastLowTouch = true;

    // Fast/Accurate has to take effect on the next dictation: the modes resolve to different models.
    bool ResolutionIsStale => resolved is { } r && r.Cleanup != settings.Cleanup;

    // Logged, so a silently-swapped model or a fall back to rules is visible rather than just slow.
    public string ActiveDescription =>
        resolved is { } r ? $"{r.Cleanup} · {OnDevice} · {r.Model}" : "Rule-based (no local model reachable)";

    // Returns (cleaned text, provider). Never throws — falls back to rules. Casing is applied out
    // here because all six exits of `CleanedAsync` end at the cursor.
    public async Task<(string Text, string Provider)> CleanAsync(string raw, AppContext context)
    {
        var result = await CleanedAsync(raw, context);
        var vocabulary = settings.Vocabulary;
        var text = NumberedList(ApplyVocabulary(result.Text, vocabulary, settings.HeardAs));
        if (settings.LowercaseSentences)
            text = LowercaseSentenceStarts(text, vocabulary);
        if (!settings.EndWithPeriod)
            text = DroppingTrailingPeriod(text);
        return (text, result.Provider);
    }

    async Task<(string Text, string Provider)> CleanedAsync(string raw, AppContext context)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return ("", "none");

        // At or below 8 words the model never runs: it is measurably worse than the rules there, and
        // the way it is worse is what users report as "it cuts off my words". Measured over 100 real
        // dictations (45 of them this short) on qwen3-0.6b: model and rules agree on 33 of 45, and of
        // the 12 disagreements the model loses content in 8 and improves 2. A skip rather than another
        // guard because none can fire here — LooksTruncated's short branch allows a 50% drop above 3
        // words, and LosesContent/DropsTail are floored at 12 content words. Re-derive from
        // history.json, not by feel. `ApplyVocabulary` runs in `CleanAsync`, so respelling still happens.
        var words = WordCount(trimmed);
        if (words <= VerbatimWords) return (RuleClean(trimmed), "rules");

        if (CurrentResolution() is not { } r) return (RuleClean(trimmed), "rules");

        // Coding gets the low-touch prompt: prose polish buys nothing and a reworded identifier costs
        // everything.
        var lowTouch = context.Category == AppCategory.Coding;
        var deadline = DeadlineMs(words, careful: settings.Cleanup == Cleanup.Accurate);

        var outcome = await AttemptAsync(r.Model, trimmed, context, lowTouch, deadline);
        switch (outcome.Kind)
        {
            case AttemptKind.Ok:
                return (outcome.Text, OnDevice);
            case AttemptKind.Deadline:
                // Not a model failure, so `resolved` stands — the model is there, it was just slow. No
                // escalation either: a bigger model is slower, and slow was the problem.
                Log.Line($"cleanup exceeded {deadline}ms; using rules");
                return (RuleClean(trimmed), "rules");
            case AttemptKind.Failed:
                Log.Line($"LLM cleanup failed ({outcome.Text}); using rule-based fallback");
                resolved = null;
                return (RuleClean(trimmed), "rules");
        }

        // A guard refused: the dictation was too disfluent for the fast model, and rules would ship
        // barely-cleaned text. One retry on the careful model — the bench says it pays.
        if (settings.Cleanup != Cleanup.Fast || FirstModel(Cleanup.Accurate) is not { } careful || careful == r.Model)
            return (RuleClean(trimmed), "rules");
        Log.Line($"cleanup escalating to {careful}");
        // Careful budget plus a cold-load allowance: LocalEngine holds one resident model, so
        // escalating swaps it out and pays that model's load plus a full prefill.
        var escalated = await AttemptAsync(careful, trimmed, context, lowTouch, DeadlineMs(words, careful: true) + 6000);
        // Re-warm: the escalation just swapped the fast model out, and without this the next
        // ordinary dictation pays the reload and misses its deadline.
        _ = WarmUpAsync();
        switch (escalated.Kind)
        {
            case AttemptKind.Ok:
                Log.Line("escalation cleaned it");
                return (escalated.Text, OnDevice);
            case AttemptKind.Rejected:
                Log.Line("escalation rejected too; using rules");
                break;
            case AttemptKind.Deadline:
                Log.Line("escalation exceeded its deadline; using rules");
                break;
            default:
                Log.Line($"escalation failed ({escalated.Text}); using rules");
                break;
        }
        return (RuleClean(trimmed), "rules");
    }

    // Rejected means a guard refused the output; unlike Deadline and Failed, a stronger model may
    // pass. Text is the cleaned text for Ok and the error for Failed.
    enum AttemptKind { Ok, Rejected, Deadline, Failed }

    record AttemptOutcome(AttemptKind Kind, string Text = "");

    class DeadlineExceeded : Exception;

    // One model's shot at the transcript: complete, sanitize, and run every guard.
    async Task<AttemptOutcome> AttemptAsync(string model, string trimmed, AppContext context, bool lowTouch, long deadline)
    {
        try
        {
            lastLowTouch = lowTouch;
            var vocabulary = settings.Vocabulary;
            var messages = StaticPrefix(vocabulary, lowTouch);
            messages.Add(new("user", UserMessage(context, trimmed)));
            var cleaned = await BeforeDeadline(deadline, ct => CompleteAsync(model, messages, ct));
            // Empty output falls back to rule-cleaned text, not the bare transcript.
            var result = Sanitize(cleaned, fallback: RuleClean(trimmed));
            if (Rejection(result, trimmed, lowTouch, AllowedTerms(vocabulary, context.DraftTerms)) is { } why)
            {
                Log.Line($"cleanup {why} ({Len(result)} of {Len(trimmed)} chars)");
                return new(AttemptKind.Rejected);
            }
            // Whatever fillers the model left in, take out deterministically.
            return new(AttemptKind.Ok, StripFillers(result));
        }
        catch (DeadlineExceeded)
        {
            return new(AttemptKind.Deadline);
        }
        catch (Exception e)
        {
            return new(AttemptKind.Failed, e.Message);
        }
    }

    // The `/no_think` switch, on its own LINE at the end of the last user message; see `CompleteAsync`
    // for the measurements. Public so `--self-check` can assert the placement.
    public static IReadOnlyList<ChatMessage> WithThinkingOff(IReadOnlyList<ChatMessage> messages, string model)
    {
        if (!model.ToLowerInvariant().Contains("qwen3") || messages.Count == 0 || messages[^1].Role != "user")
            return messages;
        var switched = messages.ToList();
        switched[^1] = switched[^1] with { Content = switched[^1].Content + "\n/no_think" };
        return switched;
    }

    // At or below this many spoken words the model is skipped; see the comment in `CleanedAsync`.
    public const int VerbatimWords = 8;

    // Cleanup's share of the latency budget; missing it ships RuleClean, so the budget is a guarantee
    // rather than an average. It scales with the transcript because a flat one is wrong both ways:
    // on qwen3-0.6b twelve words clean in 0.20s and 240 words in 1.51s, so a flat 450ms sent every
    // long dictation to the rules path. Fast's base is 900ms and not 400 because real cleanup runs
    // 280-729ms — a 400ms floor sat inside that spread and coin-flipped, four misses in five minutes
    // by 14-47ms each. Accurate carries the same headroom over a model several times the size
    // (qwen3-4b-2507 ~0.6s warm vs qwen3-0.6b ~0.2s), so both bases move together. The caps are
    // backstops for a pathological transcript, not tuned numbers. Measured on the Mac's MLX runtime:
    // llama.cpp on CPU is slower, so re-measure before trusting the Windows figures.
    public static long DeadlineMs(int words, bool careful = false) =>
        careful
            ? Math.Min(6000, 2000 + 15L * Math.Max(0, words))
            : Math.Min(2500, 900 + 6L * Math.Max(0, words));

    // Races `body` against the deadline and returns at whichever comes first. The loser is
    // cancelled: on llama.cpp that stops a generation cleanly, so unlike the Mac's MLX engine there is
    // nothing to drain behind the scenes and a deadline miss costs nothing afterwards.
    static async Task<T> BeforeDeadline<T>(long ms, Func<CancellationToken, Task<T>> body)
    {
        using var work = new CancellationTokenSource();
        using var timer = new CancellationTokenSource();
        var running = body(work.Token);
        if (await Task.WhenAny(running, Task.Delay(TimeSpan.FromMilliseconds(ms), timer.Token)) != running)
        {
            work.Cancel();
            // Nobody awaits the loser, so observe its cancellation or fault here.
            _ = running.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            throw new DeadlineExceeded();
        }
        timer.Cancel();
        return await running;
    }

    // Called as a dictation starts: if the model was freed while idle, priming it now overlaps the
    // load with the speaking instead of spending the cleanup deadline on it. The prefix of whatever
    // the last dictation used is a cache hit when the model is still warm.
    public async Task PrepareAsync()
    {
        if (resolved is not { } r) return;
        LocalEngine.Shared.KeepLoaded();
        try { await LocalEngine.Shared.WarmAsync(r.Model, StaticPrefix(settings.Vocabulary, lastLowTouch)); }
        catch (Exception e) { Log.Line($"prepare failed ({e.Message})"); }
    }

    // Resolves the model and primes both prompt prefixes so the model loads and they enter the KV
    // cache at launch instead of on the first dictation.
    public async Task WarmUpAsync()
    {
        // Build the English word list now rather than inside the first dictation's deadline.
        try { await Task.Run(() => EnglishWords.Count); }
        catch (Exception e) { Log.Line($"warm-up failed ({e.Message})"); return; }
        if (CurrentResolution() is not { } r) return;
        // No deadline here: this call is the one that loads the model. Only the resolved model —
        // LocalEngine holds ONE resident model, so warming the careful one would swap it back out and
        // hand the first real dictation a cold load. It also keeps ONE cached prompt sequence, so of
        // these two warms only the last survives: lowTouch goes last because coding is the dominant
        // context and a category switch costs only a prefix re-prefill (~0.3-0.9s), not a model load.
        foreach (var lowTouch in new[] { false, true })
        {
            try { await LocalEngine.Shared.WarmAsync(r.Model, StaticPrefix(settings.Vocabulary, lowTouch)); }
            catch (Exception e) { Log.Line($"warm-up failed ({e.Message})"); return; }
        }
        lastLowTouch = true;
        Log.Line($"warmed up {OnDevice} / {r.Model}");
    }

    // ---- Model resolution

    // The current resolution, dropped and redone when the Fast/Accurate setting has moved under it.
    Resolved? CurrentResolution()
    {
        if (ResolutionIsStale) resolved = null;
        return resolved ??= Resolve();
    }

    Resolved? Resolve()
    {
        var mode = settings.Cleanup;
        return FirstModel(mode) is { } model ? new(model, mode) : null;
    }

    // Auto-pick an instruct chat model sized by the mode. With the deadline, this is the whole
    // mechanical content of Fast vs Accurate.
    static string? FirstModel(Cleanup mode) => Pick(InstalledIds(), mode);

    static List<string> InstalledIds() => LocalEngine.InstalledModels().Select(m => m.Id).ToList();

    // Shared with `AccurateNeedsModel` so what is offered to download and what would resolve cannot
    // drift apart.
    public static string? Pick(IEnumerable<string> ids, Cleanup mode)
    {
        var chatIDs = ids.Where(id =>
        {
            var lower = id.ToLowerInvariant();
            // Reasoning variants burn seconds thinking before every dictation. Small models stay
            // eligible — LooksTruncated() catches the ones that summarize instead of cleaning.
            return !lower.Contains("embed") && !lower.Contains("whisper")
                && !lower.Contains("thinking") && !lower.Contains("reason") && !lower.Contains("-r1");
        }).ToList();
        foreach (var family in mode == Cleanup.Fast ? SmallFamilies.Concat(CarefulFamilies) : CarefulFamilies)
        {
            if (chatIDs.FirstOrDefault(id => id.ToLowerInvariant().Contains(family)) is { } match) return match;
        }
        return chatIDs.FirstOrDefault();
    }

    // Accurate is on screen with nothing behind it: it would land on the model Fast already uses.
    // Not a crash — `Pick` falls through — which is the invisible failure this makes visible.
    public static bool AccurateNeedsModel
    {
        get
        {
            var ids = InstalledIds();
            return ids.Count > 0 && Pick(ids, Cleanup.Accurate) == Pick(ids, Cleanup.Fast);
        }
    }

    // Fast, smallest first. qwen3-0.6b (bench/results.md): 0.38s median, 0/25 over budget, paid for
    // by rewording long agent-prompt cases often enough that the low-touch guard fires.
    static readonly string[] SmallFamilies = ["qwen3-0.6b", "qwen3-1.7b", "llama-3.2-1b", "gemma-3-1b"];

    // Accurate, and Fast's fallback when the machine has no small model. qwen3-4b-2507 ≈ 0.6s warm
    // and matches gpt-oss-20b (~2-3s) on quality, so it leads. Every size that matters is named
    // BEFORE the family containing it: a generic "qwen" matches the 0.6b, which silently collapses
    // Accurate onto Fast.
    static readonly string[] CarefulFamilies =
        ["qwen3-4b-2507", "qwen3-4b", "gpt-oss", "ministral", "qwen3-1.7b",
         "qwen", "llama", "mistral", "gemma"];

    // True when a model is installed, so the UI can say so before asking.
    public bool HasModel() => CurrentResolution() != null;

    // Dictionary terms for a topic (e.g. "Kubernetes and cloud infra"). [] if no model is installed.
    public async Task<List<string>> GenerateTermsAsync(string topic)
    {
        if (CurrentResolution() is not { } r) return [];
        var messages = new List<ChatMessage>
        {
            new("system", "You output vocabulary lists for a dictation app's custom dictionary. Respond with ONLY a comma-separated list of terms — product names, tools, jargon, acronyms — with their canonical spelling and capitalization. No explanations, no numbering."),
            new("user", $"List 30 technical terms, product names, and jargon someone would say while working with: {topic}"),
        };
        string output;
        try { output = await CompleteAsync(r.Model, messages); }
        catch
        {
            resolved = null;
            return [];
        }
        var seen = new HashSet<string>();
        return Sanitize(output, fallback: "")
            .Split([',', '\n', '\r', '\u0085', '\u2028', '\u2029'])
            .Select(t => t.Trim().Trim('.'))
            .Where(t => t.Length > 0 && Len(t) <= 40 && seen.Add(t.ToLowerInvariant()))
            .ToList();
    }

    // ---- Chat call

    Task<string> CompleteAsync(string model, IReadOnlyList<ChatMessage> messages, CancellationToken ct = default) =>
        // Qwen3 is a hybrid reasoner and the runtime ignores reasoning_effort and
        // chat_template_kwargs. Measured on qwen3-0.6b: without /no_think it burns ~1400 reasoning
        // tokens and 8s per dictation; with it, 1 token and 0.2s. Last message only, so the cached
        // prefix survives.
        //
        // On its OWN LINE, and that is not cosmetic: appended with a space it lands inside
        // "Transcript: <words>", and the low-touch path copies every spoken word out. Measured over 15
        // short terminal dictations: 10 of 15 wrong glued, 0 of 15 on its own line, same latency
        // (134ms vs 141ms). Adding a coding demonstration does not fix it (9 of 15 still bad).
        LocalEngine.Shared.CompleteAsync(model, WithThinkingOff(messages, model), ct);

    // ---- Swift Character semantics. The guards count and classify what a reader sees as one
    // character, not UTF-16 units, so a decomposed "é" is one letter here as it is on the Mac.

    static string[] Elements(string text)
    {
        var elements = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext()) elements.Add((string)e.Current);
        return [.. elements];
    }

    static int Len(string text) => new StringInfo(text).LengthInTextElements;

    static Rune First(string element) => Rune.GetRuneAt(element, 0);

    static bool IsLetter(string element) => Rune.IsLetter(First(element));
    static bool IsNumber(string element) => Rune.IsNumber(First(element));
    static bool IsUpper(string element) => Rune.IsUpper(First(element));
    static bool IsLower(string element) => Rune.IsLower(First(element));
    static bool IsSpace(string element) => Rune.IsWhiteSpace(First(element));
    static bool IsNewline(string element) => element is "\n" or "\r" or "\r\n" or "\v" or "\f" or "\u0085" or "\u2028" or "\u2029";

    static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
