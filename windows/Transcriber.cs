using System.Text.RegularExpressions;

namespace BisprBlow;

// On-device transcription: Parakeet (see Parakeet.cs), which prepares the clip during speech and
// transcribes it on release. There is no fallback recognizer on Windows, so until Parakeet has
// loaded a session finishes with null and the controller says so.
public sealed partial class Transcriber
{
    // Left in place after finish or cancel: `Feed` reads it on the capture thread, so only
    // `StartSessionAsync`, which runs before capture starts, replaces it. Volatile because that read
    // and the write are on different threads.
    volatile ParakeetStream? parakeet;

    // Drops the ellipsis the recognizer writes where the speaker paused: punctuation it invented,
    // not a word anybody said, and it does two kinds of damage. It reaches the cursor ("again to
    // see... If we already offloaded this work" is verbatim from history), because cleanup is told
    // never to WRITE an ellipsis and so copies this one through. Worse, it disarms a guard:
    // `looksTruncated` reads an ellipsis in the transcript as proof the speaker dictated one, so on
    // any dictation containing a pause a model that trailed off sailed through. Fixing it at the
    // source is what keeps that check armed.
    //
    // Three dots minimum, so a spoken relative path ("dot dot slash src") is not eaten. The
    // following word keeps its case — lowercasing blindly here would ruin "see... Kubernetes".
    public static string WithoutPauseMarks(string text) =>
        Spaces().Replace(PauseMark().Replace(text, " "), " ").Trim();

    [GeneratedRegex(@"\s*(\.{3,}|…)\s*")] private static partial Regex PauseMark();
    [GeneratedRegex(@"\s{2,}")] private static partial Regex Spaces();

    public Task StartSessionAsync()
    {
        parakeet = Parakeet.Shared.IsReady ? new ParakeetStream() : null;
        return Task.CompletedTask;
    }

    // The resampler is built from the buffer in hand, never from a format read earlier, so a mic at
    // another rate, or a device change mid-session, is converted correctly.
    public void Feed(float[] samples, int sampleRate, int channels) =>
        parakeet?.Append(samples, sampleRate, channels);

    // Stops the session and returns the full transcript. Null when Parakeet was not ready or failed
    // with audio in hand, which the caller must report: those words cannot be recovered. A session
    // that got no audio is "" and never reaches the recognizer.
    public async Task<string?> FinishSessionAsync()
    {
        if (parakeet is not { } stream) return null;
        var audio = stream.Finish();
        if (audio == null) return null;
        if (audio.Length == 0) return "";
        var text = await Task.Run(() => Parakeet.Shared.Transcribe(audio));
        return text == null ? null : WithoutPauseMarks(text);
    }

    // Nothing runs ahead of release, so there is nothing in flight to wait for.
    public Task CancelSessionAsync()
    {
        parakeet = null;
        return Task.CompletedTask;
    }
}
