using System.Diagnostics;
using System.IO;
using System.Text;
using LLama;
using LLama.Common;
using LLama.Native;
using LLama.Sampling;

namespace BisprBlow;

public record ChatMessage(string Role, string Content);

// In-process inference. The only file that talks to the inference library — everything else reaches it
// through `LLMCleaner`, so changing runtime touches this file. GGUF through llama.cpp, because MLX is
// Apple-only. It exists because without it every dictation degrades to unpunctuated `RuleClean`.
// One model stays resident between dictations and is freed after `IdleUnload`.
public sealed class LocalEngine
{
    public static readonly LocalEngine Shared = new();

    // llama.cpp prints every tensor it loads to stdout, which buries the CLI seams' JSON. Errors go
    // to the log; the rest is dropped.
    static LocalEngine() =>
        NativeLibraryConfig.All.WithLogCallback((level, message) =>
        {
            if (level == LLamaLogLevel.Error) Log.Line("llama " + message.TrimEnd());
        });

    // llama.cpp runs on the CPU here, so a completion is a plain loop that can stop between tokens:
    // unlike Metal there is no mid-commit abort to fear. One gate serializes load and generation, so a
    // completion whose caller gave up simply ends at its next token and the following one proceeds.
    readonly SemaphoreSlim gate = new(1, 1);
    readonly object unloadLock = new();
    CancellationTokenSource? unload;
    LLamaWeights? weights;
    LLamaContext? context;
    string? loadedId;
    // The tokens the KV cache holds for sequence 0, position i = token i.
    readonly List<LLamaToken> cached = [];

    // The model is freed after this long without a completion: the 1.7B one is 1.8 GB held for a whole
    // session otherwise. `LLMCleaner.PrepareAsync` loads it again when the shortcut is pressed.
    static readonly TimeSpan IdleUnload = TimeSpan.FromSeconds(600);
    // Bounds a model that starts looping. The context also has to hold the few-shot prefix.
    const int MaxTokens = 2048;
    const uint ContextSize = 6144;
    const float Temperature = 0.2f;

    // A dictation is starting on the loaded model, so its idle clock starts over.
    public void KeepLoaded()
    {
        if (context != null) ScheduleUnload();
    }

    // Whether llama.cpp's native library shipped beside the executable (the backend package puts it
    // under runtimes\). Models stay invisible otherwise, so a broken install gets `RuleClean` instead
    // of an exception on every dictation.
    public static bool Available { get; } =
        Directory.EnumerateFiles(System.AppContext.BaseDirectory, "llama.dll", SearchOption.AllDirectories).Any();

    // Directories scanned for models, in preference order. Home first, so a hand-placed or downloaded
    // model still wins; the one beside the executable lets a zip be unpacked and work with nothing
    // written to the profile.
    static IEnumerable<string> SearchRoots =>
        [AppPaths.Models, Path.Combine(System.AppContext.BaseDirectory, "models")];

    // Every model on disk, as (id, path). The id is the file name without ".gguf", so the Fast/Accurate
    // family matching works on it unchanged. Dot-prefixed entries are skipped: `ModelDownloader` stages
    // into `.incoming-<name>`, and that is what keeps a half-written file from ever being loaded.
    public static IReadOnlyList<(string Id, string Path)> InstalledModels()
    {
        var models = new List<(string Id, string Path)>();
        if (!Available) return models;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Scan(string dir)
        {
            IEnumerable<FileSystemInfo> entries;
            try { entries = new DirectoryInfo(dir).EnumerateFileSystemInfos().ToList(); }
            catch (IOException) { return; }
            foreach (var entry in entries)
            {
                if (entry.Name.StartsWith('.')) continue;
                if (entry is DirectoryInfo) Scan(entry.FullName);
                else if (entry.Extension.Equals(".gguf", StringComparison.OrdinalIgnoreCase)
                         && seen.Add(System.IO.Path.GetFileNameWithoutExtension(entry.Name)))
                    models.Add((System.IO.Path.GetFileNameWithoutExtension(entry.Name), entry.FullName));
            }
        }
        foreach (var root in SearchRoots) Scan(root);
        return models;
    }

    // One completion. Each prompt is diffed token by token against what the KV cache holds; only the
    // tail past the first difference is decoded. Matching on text instead is the trap: the cache holds
    // the previous reply, which the next prompt never contains, so a text match would never hit.
    public async Task<string> CompleteAsync(string id, IReadOnlyList<ChatMessage> messages,
                                            CancellationToken ct = default)
    {
        CancelUnload();
        try
        {
            await gate.WaitAsync(ct);
            try
            {
                await LoadAsync(id);
                ct.ThrowIfCancellationRequested();
                return await Task.Run(() => Generate(messages, ct), CancellationToken.None);
            }
            finally { gate.Release(); }
        }
        finally { ScheduleUnload(); }
    }

    // Loads the model and decodes `prefix` (the static part of a prompt) into the KV cache, so the first
    // dictation prefills only its own tail.
    public async Task WarmAsync(string id, IReadOnlyList<ChatMessage> prefix)
    {
        CancelUnload();
        try
        {
            await gate.WaitAsync();
            try
            {
                await LoadAsync(id);
                await Task.Run(() =>
                {
                    var started = Stopwatch.StartNew();
                    var tokens = Tokenize(prefix, assistant: false);
                    var decoded = Prefill(tokens, tokens.Length, CancellationToken.None, out _);
                    Log.Line($"local warm {started.ElapsedMilliseconds}ms {decoded} of {tokens.Length} prefix tokens decoded");
                });
            }
            finally { gate.Release(); }
        }
        finally { ScheduleUnload(); }
    }

    // Loads the model if it is not resident. Called with the gate held.
    async Task LoadAsync(string id)
    {
        if (context != null && string.Equals(loadedId, id, StringComparison.OrdinalIgnoreCase)) return;
        Free();
        var model = InstalledModels().FirstOrDefault(m => m.Id.Equals(id, StringComparison.OrdinalIgnoreCase));
        if (model.Path == null) throw new InvalidOperationException($"Model {id} is not installed.");
        var started = Stopwatch.StartNew();
        var parameters = new ModelParams(model.Path) { ContextSize = ContextSize, GpuLayerCount = 0 };
        weights = await LLamaWeights.LoadFromFileAsync(parameters);
        context = weights.CreateContext(parameters);
        loadedId = id;
        Log.Line($"local model loaded {id} in {started.ElapsedMilliseconds}ms");
    }

    string Generate(IReadOnlyList<ChatMessage> messages, CancellationToken ct)
    {
        var started = Stopwatch.StartNew();
        var ctx = context!;
        var prompt = Tokenize(messages, assistant: true);
        var room = (int)ctx.ContextSize - prompt.Length;
        if (room < 64) throw new InvalidOperationException($"The prompt is {prompt.Length} tokens, too long for the context.");

        // The last prompt token is always decoded: its logits are what the first reply token is sampled from.
        var decoded = Prefill(prompt, prompt.Length - 1, ct, out var logitsAt);
        var sampler = new DefaultSamplingPipeline
        {
            Temperature = Temperature, RepeatPenalty = 1, FrequencyPenalty = 0, PresencePenalty = 0,
        };
        var reply = new List<LLamaToken>();
        var batch = new LLamaBatch();
        try
        {
            while (reply.Count < Math.Min(MaxTokens, room))
            {
                ct.ThrowIfCancellationRequested();
                var token = sampler.Sample(ctx.NativeHandle, logitsAt);
                if (token.IsEndOfGeneration(ctx.Vocab)) break;
                reply.Add(token);
                batch.Clear();
                batch.Add(token, cached.Count, LLamaSeqId.Zero, true);
                Decode(batch);
                cached.Add(token);
                logitsAt = 0;
            }
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            ResetCache();
            throw;
        }
        finally { (sampler as IDisposable)?.Dispose(); }

        var output = ctx.DeTokenize(reply);
        Log.Line($"local completion {started.ElapsedMilliseconds}ms {output.Length}chars " +
                 $"({decoded} of {prompt.Length} prompt tokens decoded)");
        return output;
    }

    // Brings the KV cache to `tokens`, keeping at most `maxKeep` of what it already holds. Returns how
    // many tokens were decoded, and where in the final batch the logits of the last token sit.
    int Prefill(LLamaToken[] tokens, int maxKeep, CancellationToken ct, out int logitsAt)
    {
        var ctx = context!;
        var keep = 0;
        while (keep < Math.Min(maxKeep, cached.Count) && cached[keep].Equals(tokens[keep])) keep++;
        // The removal result is not reported, and a refused trim must never leave stale positions, so
        // the cache is checked and dropped whole if it did not shrink.
        if (keep < cached.Count)
        {
            ctx.NativeHandle.MemorySequenceRemove(LLamaSeqId.Zero, keep, -1);
            cached.RemoveRange(keep, cached.Count - keep);
            if (keep > 0 && ctx.NativeHandle.MemorySequenceMaxPosition(LLamaSeqId.Zero).Value >= keep)
            {
                ctx.NativeHandle.MemoryClear(true);
                cached.Clear();
                keep = 0;
            }
        }

        logitsAt = 0;
        var batch = new LLamaBatch();
        try
        {
            for (var i = keep; i < tokens.Length; i += (int)ctx.BatchSize)
            {
                ct.ThrowIfCancellationRequested();
                var part = tokens.AsSpan(i, Math.Min((int)ctx.BatchSize, tokens.Length - i));
                batch.Clear();
                batch.AddRange(part, cached.Count, LLamaSeqId.Zero, i + part.Length == tokens.Length);
                Decode(batch);
                cached.AddRange(part.ToArray());
                logitsAt = batch.TokenCount - 1;
            }
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            ResetCache();
            throw;
        }
        return tokens.Length - keep;
    }

    void ResetCache()
    {
        context?.NativeHandle.MemoryClear(true);
        cached.Clear();
    }

    void Decode(LLamaBatch batch)
    {
        var result = context!.Decode(batch);
        if (result != DecodeResult.Ok) throw new InvalidOperationException($"llama decode failed: {result}");
    }

    // The model's own chat template (llama.cpp recognises Qwen3's as ChatML). Without the assistant
    // header it renders a prefix of the full prompt, which is what `WarmAsync` needs.
    LLamaToken[] Tokenize(IReadOnlyList<ChatMessage> messages, bool assistant)
    {
        var template = new LLamaTemplate(weights!) { AddAssistant = assistant };
        foreach (var message in messages) template.Add(message.Role, message.Content);
        return context!.Tokenize(Encoding.UTF8.GetString(template.Apply()), false, true);
    }

    void Free()
    {
        cached.Clear();
        context?.Dispose();
        weights?.Dispose();
        context = null;
        weights = null;
        loadedId = null;
    }

    void CancelUnload()
    {
        lock (unloadLock) unload?.Cancel();
    }

    void ScheduleUnload()
    {
        CancellationTokenSource mine;
        lock (unloadLock)
        {
            unload?.Cancel();
            mine = unload = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(IdleUnload, mine.Token); }
            catch (OperationCanceledException) { return; }
            // A completion in flight holds the gate and reschedules when it ends.
            if (!await gate.WaitAsync(0)) return;
            try
            {
                if (mine.IsCancellationRequested || context == null) return;
                Log.Line($"local model unloaded {loadedId} after idle");
                Free();
            }
            finally { gate.Release(); }
        });
    }
}
