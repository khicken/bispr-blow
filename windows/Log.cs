using System.Diagnostics;
using System.IO;

namespace BisprBlow;

// Where the app keeps things. Roaming for what the user made (settings, history), Local for what can
// be fetched again (models, logs), the same split the Mac draws between its defaults domain and caches.
static class AppPaths
{
    public static readonly string Support = Dir(Environment.SpecialFolder.ApplicationData);
    public static readonly string Local = Dir(Environment.SpecialFolder.LocalApplicationData);
    public static readonly string Models = Path.Combine(Local, "models");

    static string Dir(Environment.SpecialFolder root)
    {
        var dir = Path.Combine(Environment.GetFolderPath(root), "BisprBlow");
        Directory.CreateDirectory(dir);
        return dir;
    }
}

// One log for the app's diagnostics: %LOCALAPPDATA%\BisprBlow\log.txt, plus the debugger. Read it with
// `Get-Content $env:LOCALAPPDATA\BisprBlow\log.txt -Tail 50 -Wait`. Counts and timings, never what was
// said: the file is readable by anything running as the user.
static class Log
{
    static readonly string File = Path.Combine(AppPaths.Local, "log.txt");
    static readonly object Gate = new();
    const long Cap = 2_000_000;

    public static void Line(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}";
        Debug.WriteLine(line);
        lock (Gate)
        {
            try
            {
                // Halved rather than deleted, so the lines leading up to a problem survive it.
                var info = new FileInfo(File);
                if (info.Exists && info.Length > Cap)
                {
                    var lines = System.IO.File.ReadAllLines(File);
                    System.IO.File.WriteAllLines(File, lines[(lines.Length / 2)..]);
                }
                System.IO.File.AppendAllText(File, line + Environment.NewLine);
            }
            catch (IOException) { }
        }
    }
}

// The stamps between pressing the dictation key and the pill being live, all from the same origin:
// a single number cannot tell a late start from a slow animation, and those need opposite fixes.
// `onStart` the hook callback reaching the controller, `pill` the pill drawn as recording,
// `session` the transcriber ready, `mic` audio actually arriving. UI thread only.
static class ActivationTrace
{
    static readonly string[] Stages = ["onStart", "pill", "session", "mic"];
    static long? edge;
    static readonly List<(string Stage, long Ms)> Marks = [];

    public static void Begin()
    {
        edge = Stopwatch.GetTimestamp();
        Marks.Clear();
    }

    public static void Mark(string stage)
    {
        if (edge is not { } start || Marks.Any(m => m.Stage == stage)) return;
        Marks.Add((stage, (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds));
        if (Marks.Count != Stages.Length) return;
        Log.Line("activation " + string.Join(" ", Marks.Select(m => $"{m.Stage}={m.Ms}ms")));
        edge = null;
    }
}
