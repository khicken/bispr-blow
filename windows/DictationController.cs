using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Threading;

namespace BisprBlow;

// Central state machine: shortcut gesture → record → transcribe → clean → insert → history.
// UI thread only; the shortcut hooks and the recorder call in from their own threads and are
// marshalled onto the dispatcher here.
public sealed class DictationController : INotifyPropertyChanged
{
    // Recording is "held" until the monitor reports the lock, then "locked" (hands-free).
    public enum Phase { Idle, Recording, Locked, Processing }

    public event PropertyChangedEventHandler? PropertyChanged;

    void Set<T>(ref T field, T value, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    Phase state = Phase.Idle;
    public Phase State { get => state; private set => Set(ref state, value); }
    bool IsRecording => state is Phase.Recording or Phase.Locked;

    // Mic level for the pill's wave, ~40 a second while recording. An event, not a property, so views
    // that observe the controller for its state do not redraw at that rate.
    public event Action<float>? Levels;

    // Transient message shown on the pill (e.g. manual-paste fallback).
    string? notice;
    public string? Notice { get => notice; private set => Set(ref notice, value); }
    // Set by the toast; holds the auto-dismiss while the pointer is on it.
    public bool NoticeHovered { get; set; }

    // A button on the current notice, when the notice is about something the app did on its own: the
    // learned-a-word message, so a change to the user's dictionary comes with the way back.
    (string Label, Action Run)? noticeAction;
    public (string Label, Action Run)? NoticeAction { get => noticeAction; private set => Set(ref noticeAction, value); }

    // Device name flashed on the pill — only when the input device changed since last time. The
    // current device is always visible in Settings.
    string? micFlash;
    public string? MicFlash { get => micFlash; private set => Set(ref micFlash, value); }

    readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    readonly ShortcutMonitor monitor = ShortcutMonitor.Shared;
    readonly AudioRecorder recorder = new();
    readonly Transcriber transcriber = new();
    readonly LLMCleaner cleaner = new();
    readonly HistoryStore history = HistoryStore.Shared;

    // Read off the UI thread at the press, awaited when the dictation is cleaned.
    Task<AppContext> context = Task.FromResult(new AppContext("", "", ""));
    DateTime recordingStartedAt = DateTime.Now;
    // Set by the "dictate and send" binding: press Enter once the text is in.
    bool sendEnter;
    // Set by the "voice command" binding: act on the app that was in front at the press.
    IntPtr? commandWindow;

    public void Start()
    {
        monitor.OnStart = BeginRecording;
        monitor.OnStop = _ => FinishRecording();
        monitor.OnCancel = CancelRecording;
        monitor.OnLock = NoteLocked;
        monitor.Start();

        // Synthesized now rather than on the first cue, which fires on the pre-mic path.
        _ = startSound;
        _ = endSound;
        _ = GetReadyAsync();
    }

    // First run: fetch the speech model, then the cleanup model, with progress on the pill. Every
    // launch after that finds them installed and goes straight to loading. There is no fallback
    // recognizer, so until Parakeet is ready a dictation says so (see `BeginRecording`).
    async Task GetReadyAsync()
    {
        var missing = new[] { ModelDownloader.Speech, ModelDownloader.Fast }.Where(i => !ModelDownloader.IsInstalled(i)).ToList();
        const string Progress = "Getting ready… ";
        var done = 0L;
        foreach (var item in missing)
        {
            var total = missing.Sum(i => i.SizeBytes);
            var before = done;
            var progress = new Progress<double>(fraction =>
            {
                // Another notice wins until it expires; the next report puts the progress back.
                if (Notice != null && !Notice.StartsWith(Progress)) return;
                Notice = $"{Progress}{(int)((before + fraction * item.SizeBytes) * 100 / total)}%";
                NoticeAction = null;
            });
            try { await ModelDownloader.DownloadAsync(item, progress); }
            catch (Exception e)
            {
                Log.Line($"model download failed: {e.Message}");
                Notice = null;
                ShowNotice("Couldn't download the models. Check your connection and restart.", 8);
                return;
            }
            done += item.SizeBytes;
        }
        if (missing.Count > 0)
        {
            Notice = null;
            ShowNotice($"Ready. {AppSettings.Shared.HoldHint}");
        }
        await Parakeet.Shared.LoadAsync();
        await cleaner.WarmUpAsync();
        Log.Line($"cleanup using {cleaner.ActiveDescription}");
    }

    void NoteLocked()
    {
        if (IsRecording) State = Phase.Locked;
        else monitor.Reset();
    }

    public void StopHandsFree() => monitor.EndLockedSession();

    public void StartHandsFree()
    {
        if (state != Phase.Idle) return;
        monitor.BeginLockedSession();
    }

    void ShowNotice(string message, double seconds = 4, (string Label, Action Run)? action = null)
    {
        Notice = message;
        NoticeAction = action;
        Dismiss(message, action == null ? seconds : Math.Max(seconds, 8));
    }

    async void Dismiss(string message, double delay)
    {
        await Task.Delay(TimeSpan.FromSeconds(delay));
        if (Notice != message) return;
        if (NoticeHovered) { Dismiss(message, 1); return; }
        Notice = null;
        NoticeAction = null;
        NoticeHovered = false;
    }

    static (string Label, Action Run) MicrophoneSettings() => ("Open Settings", Permissions.OpenMicrophoneSettings);

    void BeginRecording(ShortcutAction action)
    {
        if (state != Phase.Idle)
        {
            monitor.Reset();
            return;
        }
        if (!Permissions.MicrophoneAllowed)
        {
            monitor.Reset();
            ShowNotice("Microphone access is off. Allow it to dictate.", 8, MicrophoneSettings());
            return;
        }
        if (!Parakeet.Shared.IsReady)
        {
            monitor.Reset();
            ShowNotice("Still getting ready. Try again in a moment.");
            return;
        }
        // Speaking again means the last dictation's edits are done, before this one's text can land beside them.
        CorrectionWatcher.Cancel();
        _ = Task.Run(cleaner.PrepareAsync);
        ActivationTrace.Mark("onStart");
        sendEnter = action == ShortcutAction.PressEnter;
        commandWindow = action == ShortcutAction.Command ? ContextDetector.ForegroundWindow() : null;
        context = Task.Run(() =>
        {
            var read = ContextDetector.Current();
            // Counts, never the text: the log file is readable by anything running as the user.
            Log.Line($"context app={(read.AppName.Length == 0 ? "unknown" : read.AppName)} " +
                     $"category={read.Category} title={read.WindowTitle.Length}chars " +
                     $"draft={read.Draft.Length}chars terms={read.DraftTerms.Count}");
            return read;
        });
        var device = AudioRecorder.CurrentInputDeviceName();
        if (device != AppSettings.Shared.LastMicName)
        {
            AppSettings.Shared.LastMicName = device;
            MicFlash = device;
            // Fades on its own rather than living for the whole dictation: it is a passing
            // heads-up, and the current device is always in Settings.
            _ = Task.Delay(2500).ContinueWith(_ => { if (MicFlash == device) MicFlash = null; },
                                              TaskScheduler.FromCurrentSynchronizationContext());
        }
        PlaySound(startSound);
        recordingStartedAt = DateTime.Now;
        State = Phase.Recording;

        recorder.OnLevel = level => dispatcher.BeginInvoke(() => Levels?.Invoke(level));
        recorder.OnBuffer = (samples, rate, channels) => transcriber.Feed(samples, rate, channels);

        recorder.ResetCapturedFrames();
        _ = transcriber.StartSessionAsync();
        ActivationTrace.Mark("session");
        try { recorder.Start(); }
        catch (Exception e)
        {
            ShowNotice($"Microphone unavailable: {e.Message}", 6);
            State = Phase.Idle;
            monitor.Reset();
            _ = transcriber.CancelSessionAsync();
            return;
        }
        // The pill says "recording" from the moment the shortcut fires, but the mic only opens
        // here. Reported against the gesture edge, so "ms after shortcut" is `mic` minus `onStart`.
        ActivationTrace.Mark("mic");
    }

    void FinishRecording()
    {
        if (!IsRecording) return;
        var duration = (DateTime.Now - recordingStartedAt).TotalSeconds;
        recorder.Stop();
        Levels?.Invoke(0);
        State = Phase.Processing;

        // Nothing was captured, so there is nothing to finalise. Silence is a failure the user has
        // to be told about.
        if (recorder.CapturedFrames == 0)
        {
            Log.Line("dictation discarded: no audio captured");
            _ = transcriber.CancelSessionAsync();
            if (Permissions.MicrophoneAllowed) ShowNotice($"No audio from {AudioRecorder.CurrentInputDeviceName()}");
            else ShowNotice("Microphone access is off. Allow it to dictate.", 8, MicrophoneSettings());
            State = Phase.Idle;
            return;
        }

        _ = FinishAsync(duration);
    }

    async Task FinishAsync(double duration)
    {
        try
        {
            var released = DateTime.Now;
            var raw = await transcriber.FinishSessionAsync();
            var transcribeMs = (DateTime.Now - released).TotalMilliseconds;
            // The recognizer failed with the audio in hand. Say so: going quietly idle reads as
            // "it heard nothing", and the words are already gone.
            if (raw == null)
            {
                ShowNotice("Couldn't transcribe that. Try again.");
                State = Phase.Idle;
                return;
            }
            if (raw.Length == 0)
            {
                State = Phase.Idle;
                return;
            }
            if (commandWindow is { } window)
            {
                await RunCommandAsync(raw, window);
                State = Phase.Idle;
                return;
            }
            var heard = await context;
            var llmStart = DateTime.Now;
            var (cleaned, provider) = await cleaner.CleanAsync(raw, heard);
            var llmMs = (DateTime.Now - llmStart).TotalMilliseconds;
            Log.Line($"timings transcribe={(int)transcribeMs}ms llm={(int)llmMs}ms spoke={(int)(duration * 1000)}ms " +
                     $"provider={provider} words={cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length}");
            if (cleaned.Length > 0)
            {
                PlaySound(endSound);
                if (await TextInserter.InsertAsync(cleaned, sendEnter)) WatchForCorrection(cleaned);
                else ShowNotice("Couldn't copy that. It's in your history.");
                history.Add(new DictationEntry(Guid.NewGuid(), DateTime.UtcNow.AddTicks(-(DateTime.UtcNow.Ticks % TimeSpan.TicksPerSecond)), raw, cleaned, heard.AppName,
                                               heard.BundleID, provider, duration));
            }
            State = Phase.Idle;
        }
        catch (Exception e)
        {
            // A pill stuck on "processing" with nothing in the log is the worst way to fail.
            Log.Line($"dictation failed: {e.Message}");
            ShowNotice("Something went wrong. Try again.");
            State = Phase.Idle;
        }
    }

    void CancelRecording()
    {
        CorrectionWatcher.Cancel();
        if (!IsRecording) return;
        recorder.Stop();
        Levels?.Invoke(0);
        State = Phase.Idle;
        _ = transcriber.CancelSessionAsync();
    }

    // One cue when the mic opens, one when the text lands. Fire and forget: a sound that waits on
    // anything is late.
    //
    // Windows' own system sounds each already mean something (the default beep, the error chime, the
    // notification), so a cue borrowed from them would read as a failure on every dictation. These
    // two are synthesized once at startup instead: a few tens of ms of soft decaying sine, a lower
    // pitch for the start and a higher one for the end, which is the whole job when two sounds are
    // all that tell you whether a dictation began or ended.
    static readonly System.Media.SoundPlayer startSound = Cue(392, 0.09);
    static readonly System.Media.SoundPlayer endSound = Cue(784, 0.06);

    static System.Media.SoundPlayer Cue(double hertz, double seconds)
    {
        const int Rate = 44100;
        var count = (int)(Rate * seconds);
        var wav = new MemoryStream();
        var w = new BinaryWriter(wav);
        w.Write("RIFF"u8); w.Write(36 + count * 2); w.Write("WAVEfmt "u8);
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(count * 2);
        for (var i = 0; i < count; i++)
        {
            var t = (double)i / count;
            // A 3 ms ramp in so it never clicks, then an exponential tail out.
            var envelope = Math.Min(1, i / (Rate * 0.003)) * Math.Exp(-5 * t);
            w.Write((short)(Math.Sin(2 * Math.PI * hertz * i / Rate) * envelope * 0.25 * short.MaxValue));
        }
        wav.Position = 0;
        var player = new System.Media.SoundPlayer(wav);
        player.Load();
        return player;
    }

    static void PlaySound(System.Media.SoundPlayer sound)
    {
        if (!AppSettings.Shared.SoundsEnabled) return;
        sound.Stop();
        sound.Play();
    }

    // A word the user fixed by hand goes into the dictionary, so the next dictation spells it their
    // way. Said out loud on the pill with the way back attached: this changes a setting the user
    // owns, and doing that silently is how a dictionary starts respelling good words. Replayed over
    // history first for the same reason; the dictations still holding the mishear are the ones the
    // fix is for, so they are not evidence against it.
    void WatchForCorrection(string inserted) =>
        CorrectionWatcher.Watch(inserted, fix => dispatcher.BeginInvoke(() => Learn(fix)));

    void Learn(CorrectionWatcher.Correction fix)
    {
        var settings = AppSettings.Shared;
        // Fixed to a term already in the dictionary: the dictionary had it, so what failed was
        // hearing it. The Mac offers a heard-as for that when the audio supports it; sherpa-onnx gives
        // no such evidence, so here it is left to the Dictionary page.
        var target = fix.Corrected.Trim().Trim('.', ',', ';', ':', '!', '?', '"', '\'', '“', '”');
        if (settings.Dictionary.Any(t => string.Equals(t, target, StringComparison.OrdinalIgnoreCase))) return;
        var vocabulary = settings.Vocabulary;
        var known = vocabulary.Select(t => t.ToLowerInvariant()).ToHashSet();
        var words = LLMCleaner.LearnedWords(fix).Where(w => !known.Contains(w.ToLowerInvariant())).ToList();
        if (words.Count == 0) return;
        var dictations = history.Entries.Select(e => e.Cleaned)
            .Where(c => !c.Contains(fix.Misheard, StringComparison.OrdinalIgnoreCase)).ToList();
        _ = LearnAsync(words, vocabulary, dictations);
    }

    async Task LearnAsync(List<string> words, IReadOnlyList<string> vocabulary, List<string> dictations)
    {
        var safe = await Task.Run(() => LLMCleaner.Harmless(words, vocabulary, dictations));
        Log.Line($"correction learned={safe.Count} skipped={words.Count - safe.Count}");
        if (safe.Count == 0) return;
        var settings = AppSettings.Shared;
        settings.AddDictionaryWords(safe);
        ShowNotice($"Added {string.Join(", ", safe.Select(w => $"\"{w}\""))} to your dictionary", 6,
                   ("Undo", () => settings.Dictionary = settings.Dictionary.Where(t => !safe.Contains(t)).ToList()));
    }

    // The front app's screen is read, one element in it is acted on, and anything Jev is unsure of
    // is asked about rather than done. Labels stay out of the log: they are someone's screen.
    async Task RunCommandAsync(string spoken, IntPtr window)
    {
        if (!AppSettings.Shared.VoiceCommands)
        {
            ShowNotice("Turn on Voice commands in Settings");
            return;
        }
        var readStarted = DateTime.Now;
        var elements = await Task.Run(() => ScreenElements.Read(window));
        var readMs = (int)(DateTime.Now - readStarted).TotalMilliseconds;
        if (VoiceCommand.AppNamed(spoken, elements) is { } target)
        {
            Log.Line($"command app-switch read={readMs}ms");
            if (!await VoiceCommand.PerformAsync(target, spoken)) ShowNotice($"Couldn't switch to {target.Label}");
            return;
        }
        try
        {
            var pickStarted = DateTime.Now;
            var appName = ContextDetector.AppName(ContextDetector.ProcessId(window));
            var pick = await VoiceCommand.PickAsync(spoken, elements, appName.Length == 0 ? "the app in front" : appName);
            Log.Line($"command read={readMs}ms jev={(int)(DateTime.Now - pickStarted).TotalMilliseconds}ms " +
                     $"choices={elements.Count} confidence={pick.Confidence}");
            if (pick.Confidence < VoiceCommand.ConfidentEnough || VoiceCommand.NeedsConfirmation(pick.Element))
            {
                ShowNotice($"{(pick.Confidence >= VoiceCommand.ConfidentEnough ? "Press" : "Did you mean")} {pick.Element.Label}?", 8,
                           ("Do it", async () =>
                           {
                               // The element belongs to the app the command was said in; elsewhere it presses nothing sensible.
                               if (ContextDetector.ForegroundWindow() != window || !await VoiceCommand.PerformAsync(pick.Element, spoken))
                                   ShowNotice($"Couldn't do that: {pick.Element.Label}");
                           }));
                return;
            }
            if (!await VoiceCommand.PerformAsync(pick.Element, spoken)) ShowNotice($"Couldn't do that: {pick.Element.Label}");
        }
        catch (VoiceCommand.FailureException e) when (e.Kind == VoiceCommand.Failure.NoKey)
        {
            ShowNotice("Voice commands need a TypeSafe key in your Credential Manager");
        }
        catch (VoiceCommand.FailureException e) when (e.Kind == VoiceCommand.Failure.KeyRejected)
        {
            ShowNotice("TypeSafe rejected the key in your Credential Manager");
        }
        catch (Exception e)
        {
            Log.Line($"command failed error={e.Message}");
            ShowNotice("Couldn't reach Jev");
        }
    }
}
