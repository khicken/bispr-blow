using System.Text.RegularExpressions;

namespace BisprBlow;

public partial class LLMCleaner
{
    // True when cleanup clearly lost content: it elided part of the transcript, or came back far
    // shorter. An ellipsis anywhere counts: `Transcriber.WithoutPauseMarks` strips the recognizer's at the source, so one here is the model eliding. Length is judged against
    // the transcript with fillers ALREADY removed: judging against the raw count builds in a bias as
    // large as the filler share, so "um um so uh uh i think we should just ship it um today and see
    // what breaks", correctly cleaned to nine words, was rejected because 55% of the raw 18 is 10.
    public static bool LooksTruncated(string cleaned, string raw)
    {
        static bool Elides(string text) => text.Contains("...") || text.Contains('…');
        if (Elides(cleaned) && !Elides(raw)) return true;
        var rawWords = WordCount(raw);
        var cleanedWords = WordCount(cleaned);
        // Far longer than the transcript is not a cleanup: a leaked reasoning trace, or the model
        // answering the dictation instead of tidying it.
        if (rawWords >= 5 && cleanedWords > (int)(rawWords * 2.5)) return true;
        var spokenWords = WordCount(RuleClean(raw));
        if (spokenWords < 12)
        {
            // Short dictations legitimately vary, so the floor is half rather than 0.55 — but not
            // unguarded: "Blue Jays, Blue Jays, Blue Jays" came back as "blue Jays.", six words to two.
            return spokenWords >= 3 && cleanedWords < (int)Math.Ceiling(spokenWords * 0.5);
        }
        return cleanedWords < (int)(spokenWords * 0.55);
    }

    // Content-word recall: did the words carrying the meaning survive? Counting words is not enough —
    // a 45-word dictation came back at 24 with its whole second half deleted and PASSED, because 24
    // clears 55% of the filler-stripped 40. Which half the survivors came from is what matters.
    //
    // Complements the others: LooksTruncated catches gross length collapse, RewordsContent catches a
    // swap on the coding path, and this catches deletion on both paths. Function words are excluded
    // via the recognizer's own list, so "we should probably" → "we should" is free.
    //
    // 0.8, and the margin is thinner than it looks: distinct words are counted, so the dictation above
    // lost 53% of its text but only 25% of its content vocabulary, scoring exactly 0.75. Measured
    // recall across bench/cases.json is 94-96%, so 0.8 keeps ~14 points of clearance.
    public const double ContentRecallFloor = 0.8;

    public static bool LosesContent(string cleaned, string raw)
    {
        var spoken = ContentWords(raw).ToHashSet();
        // Below this a single dropped word swings the ratio too far to judge anything.
        if (spoken.Count < 12) return false;
        var kept = spoken.Intersect(ContentWords(cleaned)).Count();
        return kept < spoken.Count * ContentRecallFloor;
    }

    // Did the last thing the speaker said survive? Both ratios above are structurally blind to
    // "stopped early": a dictation ending "It should be really easy to do that." came back without
    // that sentence at 50 words of 57 — 88% against a 55% floor and ~90% content recall against 0.8.
    // Position is what a ratio throws away.
    //
    // The very last content word, not the last few; on that case the dropped sentence contributes
    // exactly one. Two looseners are load-bearing rather than defensive: the 12-word floor (on a short
    // dictation the final word is as likely to be a discarded "yeah"), and substring rather than
    // equality, since a respelling or a plural fix is not a deletion.
    //
    // Measured over bench/cases.json, both models, 3 reps: fires on 0 of 27 real outputs while catching
    // the repro and 2 of 5 multi-sentence cases with their last sentence deleted. It misses
    // `snap_regions` — its final word is "picked" and the transcript said "pick" — and that trade is
    // deliberate: a rejection ships RuleClean, so the false-positive rate is what decides this guard.
    public static bool DropsTail(string cleaned, string raw)
    {
        var spoken = ContentWords(raw);
        if (spoken.Count < 12) return false;
        var last = spoken[^1];
        // Position, not presence: searching all of `cleaned` lets an earlier occurrence satisfy it,
        // which is how a 157-word dictation silently lost its closing "...then that's for the cleanup
        // too" — "cleanup" also appeared 90 words earlier, at index 38 of 128. Requiring the match in
        // the last quarter is what makes "compressed the middle" distinguishable from "gave up".
        var output = Tokens(cleaned);
        var tail = output.Skip(Math.Max(0, output.Count - Math.Max(8, output.Count / 4)));
        // Prefix is for morphology, not a shorter unrelated word: "region" for "regions" is the same
        // word, "clean" for "cleanup" is not — the second half of that same miss, whose surviving tail
        // ended "should clean that up". One character of slack covers plural and possessive.
        return !tail.Any(t =>
            t.Contains(last)
            || (Len(t) >= 4 && last.StartsWith(t, StringComparison.Ordinal) && Len(last) - Len(t) <= 1));
    }

    // Did a whole sentence go? The guards above judge the dictation as one bag of words and are
    // floored at 12 content words, so one lost sentence in sixty words clears all of them. A sentence
    // is gone when under half of its content words survive; two is enough to judge, because
    // `AppContext.CommonWords` is broad and "bypass permissions" is all "I have bypass permissions on." has.
    public static bool DropsSentence(string cleaned, string raw)
    {
        var output = Tokens(cleaned);
        return Regex.Replace(raw, @"(?<=[.!?])\s+", "\n")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Any(sentence =>
            {
                var content = ContentWords(sentence);
                if (content.Count < 2) return false;
                // Substring, as in DropsTail: a respelling or a plural fix is not a deletion.
                var kept = content.Count(word => output.Any(t => t.Contains(word)));
                return kept * 2 < content.Count;
            });
    }

    public static List<string> Tokens(string text)
    {
        var tokens = new List<string>();
        var word = new System.Text.StringBuilder();
        foreach (var element in Elements(text.ToLowerInvariant()))
        {
            if (IsLetter(element) || IsNumber(element)) { word.Append(element); continue; }
            if (word.Length > 0) tokens.Add(word.ToString());
            word.Clear();
        }
        if (word.Length > 0) tokens.Add(word.ToString());
        return tokens;
    }

    public static List<string> ContentWords(string text) =>
        Tokens(text).Where(t => Len(t) >= 3 && !AppContext.CommonWords.Contains(t)).ToList();

    // Every guard in one place — they had already drifted: `--finish`, the seam bench.py scores
    // through, never ran `LosesContent`, so that guard's false-positive rate had never been measured
    // on the set that exists to measure it. The strings are what the log and `--finish` print.
    public const string Truncated = "dropped content";
    public const string LostContent = "lost content words";
    public const string DroppedTail = "dropped the last thing said";
    public const string DroppedSentence = "dropped a whole sentence";
    public const string Reworded = "reworded content on the coding path";

    // Null when `cleaned` is accepted, otherwise one of the reasons above.
    public static string? Rejection(string cleaned, string raw, bool lowTouch, IReadOnlySet<string> allowed)
    {
        // Small models summarize long dictations or stop mid-sentence. Losing the speaker's words is
        // worse than leaving fillers in.
        if (LooksTruncated(cleaned, raw)) return Truncated;
        // Both paths: the meaning-carrying words have to still be there, even at an acceptable count.
        if (LosesContent(cleaned, raw)) return LostContent;
        // And the one that catches it stopping at the very end, where neither ratio can see it.
        if (DropsTail(cleaned, raw)) return DroppedTail;
        if (DropsSentence(cleaned, raw)) return DroppedSentence;
        // Low touch promised delete/repunctuate/respell only. Check it: a swap leaves the length alone.
        if (lowTouch && RewordsContent(cleaned, raw, allowed)) return Reworded;
        return null;
    }

    internal static readonly IReadOnlySet<string> NoTerms = new HashSet<string>();

    // The low-touch invariant, checked instead of trusted: every output word is traceable to the
    // transcript in spoken order, or to the closed set the user gave us (dictionary + on-screen
    // words), which is where "work tree" → "worktree" comes from.
    //
    // Catches rewording — a swapped word, an invented connective, a reordering — and is deliberately
    // blind to deletion and capitalization, so it complements `LooksTruncated` rather than replacing
    // it. Two exemptions, or it fires on ordinary output: a token starting with a digit ("200",
    // "500s") is a rendering of spoken number words, and two spoken words written as one ("back off"
    // → "backoff") is a deleted space.
    public static bool RewordsContent(string cleaned, string raw, IReadOnlySet<string>? allowed = null)
    {
        allowed ??= NoTerms;
        var source = Tokens(raw);
        var next = 0;  // order matters: only ever scan forward
        foreach (var word in Tokens(cleaned))
        {
            if (IsNumber(Elements(word)[0]) || allowed.Contains(word)) continue;
            var hit = source.IndexOf(word, next);
            if (hit >= 0) { next = hit + 1; continue; }
            // "back off" → "backoff": the pair has to sit at the scan head, or a compound could be
            // assembled from two words at opposite ends of the transcript.
            var pair = -1;
            for (var i = next; i + 1 < source.Count; i++)
                if (source[i] + source[i + 1] == word) { pair = i; break; }
            if (pair >= 0) { next = pair + 2; continue; }
            // A digit going back to the word it was heard as — the mirror of the exemption above.
            var digit = -1;
            for (var i = next; i < source.Count; i++)
                if (DigitHomophones.TryGetValue(source[i], out var words) && words.Contains(word)) { digit = i; break; }
            if (digit >= 0) { next = digit + 1; continue; }
            return true;
        }
        return false;
    }

    // What each digit may be turned back into, and nothing else. The recognizer decides between
    // "for", "fore" and "four" on sound alone and then formats the number: "Just keep the best 4 and
    // afterwards text." A closed table rather than "any word may replace a digit", which would licence
    // rewriting every number. Only 0-10: past ten the numeral is almost always what was meant.
    static readonly Dictionary<string, HashSet<string>> DigitHomophones = new()
    {
        ["0"] = ["zero", "oh", "owe"],
        ["1"] = ["one", "won"],
        ["2"] = ["two", "to", "too"],
        ["3"] = ["three"],
        ["4"] = ["four", "for", "fore"],
        ["5"] = ["five"],
        ["6"] = ["six"],
        ["7"] = ["seven"],
        ["8"] = ["eight", "ate"],
        ["9"] = ["nine"],
        ["10"] = ["ten"],
    };

    // Everything the recognizer was biased toward — the dictionary plus the words on screen —
    // tokenized the way `RewordsContent` does, so respelling to a term the user gave us is allowed
    // and inventing one is not.
    public static IReadOnlySet<string> AllowedTerms(IEnumerable<string> vocabulary, IEnumerable<string> draftTerms) =>
        vocabulary.Concat(draftTerms).SelectMany(Tokens).ToHashSet();
}
