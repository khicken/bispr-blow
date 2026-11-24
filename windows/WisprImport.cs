using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace BisprBlow;

// What Wispr Flow learned, read from its own database so switching apps does not start the
// dictionary over. Opened read-only: Wispr Flow is never written to. It is an Electron app, so its
// data sits in %APPDATA%\Wispr Flow, the same file name as the Mac's Application Support folder. The
// reader is the SQLite that ships with Windows 10+ (winsqlite3.dll), which keeps a package out of the build.
public static class WisprImport
{
    public static readonly string Database = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Wispr Flow", "flow.sqlite");

    public static bool IsInstalled => File.Exists(Database);

    // Why a read failed, for the one line of UI copy. Not installed is checked first, because a
    // missing database also makes the read fail.
    public static string FailureMessage => IsInstalled
        ? "Couldn't read Wispr Flow's data. Quit it and try again"
        : "Wispr Flow isn't installed";

    // Wispr Flow's own icon, read from the installed app, so the row is recognised at a glance and
    // nothing of Wispr Flow's is copied into this repo. Null when the installer put it somewhere else.
    public static ImageSource? AppIcon
    {
        get
        {
            var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                   "Programs", "Wispr Flow", "Wispr Flow.exe");
            if (!File.Exists(exe) || System.Drawing.Icon.ExtractAssociatedIcon(exe) is not { } icon) return null;
            return System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(icon.Handle, System.Windows.Int32Rect.Empty,
                                                       BitmapSizeOptions.FromEmptyOptions());
        }
    }

    // Wispr Flow's dictionary words, then the one-word fixes in its history; null when the database
    // cannot be read. Snippets and replacements are skipped because there is nothing here to hold
    // them, and a word Wispr Flow auto-learned but never used again is more often a typo than a name.
    // Most-used first, so that spelling wins when Wispr Flow holds two ("Livekit", "LiveKit").
    public static List<string>? LearnedWords(IReadOnlyList<string> alongside)
    {
        if (sqlite3_open_v2(Database, out var db, ReadOnly, IntPtr.Zero) != 0) { sqlite3_close(db); return null; }
        try
        {
            if (Rows(db, """
                    SELECT phrase FROM Dictionary
                    WHERE isDeleted = 0 AND isSnippet = 0 AND coalesce(replacement, '') = ''
                      AND (coalesce(source, '') != 'user_edits' OR frequencyUsed > 1)
                    ORDER BY frequencyUsed DESC
                    """) is not { } words
                || Rows(db, "SELECT formattedText, editedText FROM History WHERE formattedText != ''") is not { } history)
                return null;
            var edits = history.Where(r => r[1].Length > 0).Select(r => (Written: r[0], Edited: r[1]));
            var dictations = history.Select(r => r[1].Length == 0 ? r[0] : r[1]);
            return LLMCleaner.Harmless(words.Select(r => r[0]).Concat(Corrections(edits)), alongside, dictations);
        }
        finally { sqlite3_close(db); }
    }

    // Wispr Flow's history is the same signal `CorrectionWatcher` waits for, after the fact, so it is
    // held to the same bar.
    public static List<string> Corrections(IEnumerable<(string Written, string Edited)> edits) =>
        edits.Select(e => CorrectionWatcher.Substitution(e.Written, e.Edited))
             .OfType<CorrectionWatcher.Correction>().SelectMany(LLMCleaner.LearnedWords).ToList();

    // Adds the words the dictionary does not already hold, and returns them. A word already known in
    // any casing is left alone, so the import never re-cases something the user settled here.
    public static List<string> Add(IEnumerable<string> words, AppSettings settings)
    {
        var known = settings.Vocabulary.Select(w => w.ToLowerInvariant()).ToHashSet();
        var added = words.Select(w => w.Trim()).Where(w => w.Length > 0 && known.Add(w.ToLowerInvariant())).ToList();
        settings.AddDictionaryWords(added);
        return added;
    }

    // `--import-wispr`. Quit the app first: a running app holds its own copy of the dictionary and
    // saves it over whatever this adds.
    public static int RunCli()
    {
        if (LearnedWords(AppSettings.Shared.Vocabulary) is not { } words)
        {
            Console.WriteLine($"could not read {Database}");
            return 1;
        }
        foreach (var word in Add(words, AppSettings.Shared)) Console.WriteLine(word);
        return 0;
    }

    // Null unless every row was read: a busy or failing read must not pass for a short dictionary.
    static List<string[]>? Rows(IntPtr db, string sql)
    {
        if (sqlite3_prepare_v2(db, sql, -1, out var statement, IntPtr.Zero) != 0) return null;
        try
        {
            var rows = new List<string[]>();
            int status;
            while ((status = sqlite3_step(statement)) == Row)
                rows.Add(Enumerable.Range(0, sqlite3_column_count(statement))
                    .Select(c => Marshal.PtrToStringUTF8(sqlite3_column_text(statement, c)) ?? "").ToArray());
            return status == Done ? rows : null;
        }
        finally { sqlite3_finalize(statement); }
    }

    const int ReadOnly = 1, Row = 100, Done = 101;

    [DllImport("winsqlite3.dll")]
    static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll")]
    static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_column_count(IntPtr statement);
    [DllImport("winsqlite3.dll")] static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_close(IntPtr db);
}
