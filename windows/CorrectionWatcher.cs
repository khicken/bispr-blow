using System.Windows.Automation;

namespace BisprBlow;

// Learns the words the app gets wrong, from the user fixing them. A misheard name stays misheard
// until it is in the dictionary, and the only cure was remembering to open the Dictionary page. So
// after text lands, the field it landed in is watched until the user sends it, clears it or moves
// on, and the last text seen is compared with what was inserted: one short stretch replaced is a
// correction worth keeping. Deliberately not a keystroke hook — reading every key the user presses in
// another app is a keylogger's shape, and this needs only a before and an after.
// UI thread only.
static class CorrectionWatcher
{
    // A cap, not the usual end: a chat box clears on send, which settles the watch long before this.
    static readonly TimeSpan Window = TimeSpan.FromSeconds(120);
    static readonly TimeSpan Interval = TimeSpan.FromSeconds(0.5);

    static CancellationTokenSource? cancellation;
    static (string Inserted, string Planted, string LastSeen, Action<Correction> OnCorrection)? pending;

    // A correction the user made: what BisprBlow wrote, and what they replaced it with. Up to
    // `LongestFix` words on either side.
    public record Correction(string Misheard, string Corrected);

    const int LongestFix = 3;

    // Watches the field the text just landed in.
    public static void Watch(string inserted, Action<Correction> onCorrection)
    {
        Cancel();
        if (inserted.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length < 2
            || ContextDetector.FocusedElement() is not { } focus) return;
        cancellation = new CancellationTokenSource();
        _ = Run(focus.Element, focus.Pid, inserted, onCorrection, cancellation.Token);
    }

    static async Task Run(AutomationElement element, int pid, string inserted, Action<Correction> onCorrection, CancellationToken token)
    {
        try
        {
            // The paste has to land before there is anything to compare against.
            await Task.Delay(1000, token);
            if (await Task.Run(() => ContextDetector.FocusedText(element)) is not { } planted) return;
            token.ThrowIfCancellationRequested();
            pending = (inserted, planted, planted, onCorrection);
            var deadline = DateTime.UtcNow + Window;
            // Sent, cleared, or left for another app: the last text seen is what the user settled on.
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(Interval, token);
                if (ContextDetector.ProcessId(ContextDetector.ForegroundWindow()) != pid
                    || await Task.Run(() => ContextDetector.FocusedText(element)) is not { } current) break;
                token.ThrowIfCancellationRequested();
                pending = pending is { } watch ? watch with { LastSeen = current } : null;
            }
            Settle();
        }
        catch (OperationCanceledException) { }
    }

    // Settles rather than drops: whatever the user fixed before this point is final. Judges the last
    // text the poll saw, since a fresh read here would stall the shortcut that is cancelling.
    public static void Cancel()
    {
        Settle();
        cancellation?.Cancel();
        cancellation = null;
    }

    static void Settle()
    {
        if (pending is not { } watch) return;
        pending = null;
        if (Substitution(watch.Planted, watch.LastSeen) is { } fix
            && watch.Inserted.Contains(fix.Misheard, StringComparison.CurrentCultureIgnoreCase))
            watch.OnCorrection(fix);
    }

    // The one stretch of up to `LongestFix` words that changed, or null. Null for an insertion, a
    // deletion, two edits around a kept word, a reflowed paragraph: those are the user writing, and there is
    // no telling which half of a rewrite was a mishear. A wrong entry respells words that were
    // already right. Words compare without their punctuation, which belongs to the sentence.
    public static Correction? Substitution(string before, string after)
    {
        var old = before.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var now = after.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        static bool Same(string a, string b) => a.Trim(AppContext.Punctuation) == b.Trim(AppContext.Punctuation);
        var start = 0;
        while (start < Math.Min(old.Length, now.Length) && Same(old[start], now[start])) start++;
        int oldEnd = old.Length, newEnd = now.Length;
        while (oldEnd > start && newEnd > start && Same(old[oldEnd - 1], now[newEnd - 1]))
        {
            oldEnd--;
            newEnd--;
        }
        var oldSpan = old[start..oldEnd];
        var newSpan = now[start..newEnd];
        if (oldSpan.Length is < 1 or > LongestFix || newSpan.Length is < 1 or > LongestFix
            || oldSpan.Any(word => newSpan.Any(other => Same(word, other)))) return null;

        var misheard = string.Join(" ", oldSpan).Trim(AppContext.Punctuation);
        var corrected = string.Join(" ", newSpan).Trim(AppContext.Punctuation);
        return misheard.Length == 0 || corrected.Length == 0 ? null : new Correction(misheard, corrected);
    }
}
