using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BisprBlow;

// The entry point, and the same command-line seams the Mac binary has, so each piece can be driven
// and measured without the keyboard. A WinExe has no console of its own; it borrows the one it was
// started from, and piped output works either way.
static class Program
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0].StartsWith("--"))
        {
            AttachConsole(-1);
            Console.OutputEncoding = System.Text.Encoding.UTF8;
            return Cli(args).GetAwaiter().GetResult();
        }
        // One copy at a time: two copies means two keyboard hooks fighting over one shortcut.
        using var single = new Mutex(true, @"Local\ai.getbluejay.bisprblow", out var first);
        // A second launch (a Start-menu click, or the bisprblow:// sign-in callback) hands its arguments
        // to the running copy, which shows the dashboard or finishes the sign-in.
        if (!first) { App.SignalRunningCopy(args); return 0; }
        var app = new App { StartupArgs = args };
        app.InitializeComponent();
        return app.Run();
    }

    static string? Arg(string[] args, string flag) =>
        Array.IndexOf(args, flag) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;

    static JsonObject Stdin() =>
        JsonNode.Parse(Console.In.ReadToEnd() is { Length: > 0 } s ? s : "{}") as JsonObject ?? [];

    static void Print(object value) => Console.WriteLine(JsonSerializer.Serialize(value));

    static async Task<int> Cli(string[] args)
    {
        var settings = AppSettings.Shared;
        switch (args[0])
        {
            case "--self-check":
                return SelfCheck.Run();

            // Drives the real AudioRecorder for two seconds against the selected device.
            case "--mic-check":
            {
                var recorder = new AudioRecorder();
                Console.WriteLine($"device: {AudioRecorder.CurrentInputDeviceName()}");
                var started = DateTime.Now;
                try { recorder.Start(); }
                catch (Exception e) { Console.WriteLine($"FAIL — start threw: {e.Message}"); return 1; }
                Console.WriteLine($"startup: {(int)(DateTime.Now - started).TotalMilliseconds}ms");
                await Task.Delay(2000);
                var frames = recorder.CapturedFrames;
                recorder.Stop();
                Console.WriteLine($"frames: {frames}");
                Console.WriteLine(frames > 0 ? "PASS — see the `audio` line in the log for level" : "FAIL — no audio captured");
                return frames > 0 ? 0 : 1;
            }

            // WAV files through the real Transcriber in 100ms buffers, one JSON line each in
            // bench/asr's runner format, so `ms` is the wait after release.
            case "--transcribe":
            {
                await Parakeet.Shared.LoadAsync();
                if (!Parakeet.Shared.IsReady) { Console.WriteLine("FAIL — Parakeet did not load"); return 1; }
                var transcriber = new Transcriber();
                foreach (var path in args.Skip(1))
                {
                    var (samples, rate, channels) = AudioRecorder.ReadWav(path);
                    await transcriber.StartSessionAsync();
                    var step = rate / 10 * channels;
                    for (var offset = 0; offset < samples.Length; offset += step)
                    {
                        transcriber.Feed(samples[offset..Math.Min(offset + step, samples.Length)], rate, channels);
                        await Task.Delay(100);
                    }
                    var start = DateTime.Now;
                    var text = await transcriber.FinishSessionAsync() ?? "FAILED";
                    Print(new { file = Path.GetFileName(path), text, ms = (int)(DateTime.Now - start).TotalMilliseconds });
                }
                return 0;
            }

            // bench/bench.py reads the real prompts from here so they can never drift from the app.
            case "--print-prompt":
                Console.WriteLine(JsonSerializer.Serialize(new Dictionary<string, string>
                {
                    ["default"] = LLMCleaner.StaticPrefix(settings.Vocabulary, lowTouch: false),
                    ["lowTouch"] = LLMCleaner.StaticPrefix(settings.Vocabulary, lowTouch: true),
                }, new JsonSerializerOptions { WriteIndented = true }));
                return 0;

            // The dictionary respeller alone, against the real dictionary, one line of stdin per case.
            case "--vocab":
                while (Console.ReadLine() is { } line)
                    Console.WriteLine(LLMCleaner.ApplyVocabulary(line, settings.Vocabulary, settings.HeardAs));
                return 0;

            // Everything `clean` does to a model's reply after the call, so the bench scores the text
            // that would land at the cursor. stdin {"raw","cleaned","lowTouch"?,"draftTerms"?}.
            case "--finish":
            {
                var input = Stdin();
                var raw = (string?)input["raw"] ?? "";
                var result = LLMCleaner.Sanitize((string?)input["cleaned"] ?? "", fallback: LLMCleaner.RuleClean(raw));
                var lowTouch = (bool?)input["lowTouch"] ?? false;
                var draftTerms = input["draftTerms"]?.AsArray().Select(n => (string)n!).ToList() ?? [];
                var why = LLMCleaner.Rejection(result, raw, lowTouch, LLMCleaner.AllowedTerms(settings.Vocabulary, draftTerms));
                Print(new
                {
                    lossy = why != null,
                    reworded = why == "reworded",
                    reason = why,
                    text = why != null ? LLMCleaner.RuleClean(raw) : LLMCleaner.StripFillers(result),
                });
                return 0;
            }

            // The whole cleanup path against the local model: resolution, prompt, guards, escalation.
            // stdin {"raw","bundleID"?,"appName"?} → {"text","provider"}.
            case "--clean":
            {
                var input = Stdin();
                var context = new AppContext((string?)input["bundleID"] ?? "WindowsTerminal",
                                             (string?)input["appName"] ?? "Terminal", "");
                var cleaner = new LLMCleaner();
                await cleaner.WarmUpAsync();
                var (text, provider) = await cleaner.CleanAsync((string?)input["raw"] ?? "", context);
                Print(new { text, provider });
                return 0;
            }

            // One JSON request per stdin line, {"model","messages"} → {"content"|"error","ms"}.
            case "--complete":
                while (Console.ReadLine() is { Length: > 0 } line)
                {
                    var request = JsonNode.Parse(line)!;
                    var messages = request["messages"]!.AsArray()
                        .Select(m => new ChatMessage((string)m!["role"]!, (string)m["content"]!)).ToList();
                    var started = DateTime.Now;
                    try
                    {
                        var content = await LocalEngine.Shared.CompleteAsync((string)request["model"]!, messages);
                        Print(new { content, ms = (int)(DateTime.Now - started).TotalMilliseconds });
                    }
                    catch (Exception e) { Print(new { error = e.Message, ms = (int)(DateTime.Now - started).TotalMilliseconds }); }
                }
                return 0;

            case "--list-models":
                foreach (var model in LocalEngine.InstalledModels()) Console.WriteLine(model.Id);
                return 0;

            // Fetch the weights a fresh machine needs, with progress. build.ps1 calls these.
            case "--download-fast":
                return await ModelDownloader.DownloadCliAsync(ModelDownloader.Fast);
            case "--download-accurate":
                return await ModelDownloader.DownloadCliAsync(ModelDownloader.Accurate);
            case "--download-speech":
                return await ModelDownloader.DownloadCliAsync(ModelDownloader.Speech);

            // The real releases/latest request and the real comparison, against a given version.
            case "--update-check":
            {
                var current = Arg(args, "--update-check") ?? "0.0.0";
                Console.WriteLine($"current={current}");
                await UpdateChecker.Shared.CheckAsync(current);
                Console.WriteLine(UpdateChecker.Shared.Latest is { } latest
                    ? $"latest={latest} — behind, the banner shows" : "up to date (or offline) — no banner");
                return 0;
            }

            case "--cloud-check":
                return await CloudClient.CheckCliAsync();

            case "--import-wispr":
                return WisprImport.RunCli();

            // The front window's actionable elements after a delay, as a voice command would see them.
            case "--dump-elements":
                return await ScreenElements.DumpCliAsync(int.TryParse(Arg(args, "--dump-elements"), out var d) ? d : 3);

            default:
                Console.WriteLine($"unknown flag {args[0]}");
                return 2;
        }
    }
}
