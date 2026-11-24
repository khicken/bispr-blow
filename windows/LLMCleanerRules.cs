using System.Text.RegularExpressions;

namespace BisprBlow;

public partial class LLMCleaner
{
    // These regexes are built per call from a handful of patterns, so the default cache of 15 would
    // recompile them on every dictation.
    static LLMCleaner() => Regex.CacheSize = 128;

    // ---- Deterministic filler removal

    // Removes the fillers a regex gets right every time. Runs on the model's output too: measured on
    // qwen3-0.6b, the model leaves "uh" and discourse "like" in about as often as it strips them.
    //
    // Two tiers, because the cost of a mistake is asymmetric. "um" and friends are never words, and
    // neither are "oh", "hm", "hmm". "like" and "you know" are, so those are only touched in the
    // shapes a real use never takes.
    static readonly string[] HardFillers = ["um", "umm", "ummm", "uh", "uhh", "uhhh",
                                            "er", "erm", "ah", "oh", "hm", "hmm"];
    // Words a comma after a filler follows. In history.json, a comma there almost always punctuated
    // only the filler ("for, um, red"); "sign in, uh, then" loses a real one, and keeps its words.
    static readonly string[] MidClauseWords = ["the", "a", "an", "for", "on", "of", "to", "in", "at", "with",
                                               "from", "and", "but", "or", "because", "if", "our", "your",
                                               "my", "their", "his", "her", "its", "is", "are", "was", "be",
                                               "very"];

    public static string StripFillers(string text)
    {
        var hard = string.Join("|", HardFillers);
        var mid = string.Join("|", MidClauseWords);
        // A filler standing as its own sentence takes its full stop with it, or "Oh. Uh. the login
        // flow" comes out "Oh.. the login flow". Looped: one call rewrites each match once and a
        // consumed separator stops the next match starting, and these arrive in runs.
        var standalone = $@"(?i)(^|[.!?]\s+|\u0001)(?:{hard})\s*[.!?]+\s*";
        while (true)
        {
            var next = Regex.Replace(text, standalone, "$1\u0001");
            if (next == text) break;
            text = next;
        }
        // Opening a sentence, comma or no comma. The next word takes the capital the filler held.
        text = Regex.Replace(text, $@"(?i)(^|[.!?]\s+|\u0001)(?:{hard}),?\s+", "$1\u0001");
        // A filler carries off the comma punctuating it, or removing the word strands it against the
        // previous one ("Update the uh, this cookbook, Doc." → "Update the, this cookbook, Doc.") —
        // and a dictation at or under `VerbatimWords` gets no model pass to tidy it. One pass, not
        // two: the leading `[\s\u0001]` also matches the space inside ", um,", so a comma-bracketed
        // filler collapses to a single comma. That comma is right after "Basically" and wrong after
        // "is" ("is, um, standard"), so after a word in `MidClauseWords` both commas go first.
        text = Regex.Replace(text, $@"(?i)\b({mid})\s*,\s*(?:{hard})\s*,\s*", "$1 ");
        text = Regex.Replace(text, $@"(?i)(^|[\s\u0001])(?:{hard})\s*,\s*", "$1");
        // Anywhere else. `(^|[\s,\u0001])` keeps "umbrella" and "uh-huh" intact, and counts a marker
        // left above as a word boundary so "um uh the tests" loses both fillers.
        foreach (var filler in HardFillers)
            text = Regex.Replace(text, $@"(?i)(^|[\s,\u0001]){filler}([\s,.!?]|$)", "$1$2");
        foreach (var hedge in new[] { "like", "you know" })
        {
            // Bracketed by commas: "it was, like, really slow". A real "like" is never bracketed.
            // Replaced by a space — the commas were only there for the hedge.
            text = Regex.Replace(text, $@"(?i),\s*{hedge}\s*,\s*", " ");
            // Trailing: "it's too slow, you know."
            text = Regex.Replace(text, $@"(?i),\s*{hedge}\s*([.!?]|$)", "$1");
        }
        // Opening a sentence: "Too high. Like, way too high." \u0001 marks where the capital goes;
        // a transcript never contains one.
        text = Regex.Replace(text, @"(?i)(^|[.!?]\s+)(?:like|you know),\s*", "$1\u0001");
        for (var mark = text.IndexOf('\u0001'); mark >= 0; mark = text.IndexOf('\u0001'))
        {
            var rest = text[(mark + 1)..];
            var head = rest.Length > 0 ? Elements(rest)[0] : "";
            text = text[..mark] + head.ToUpperInvariant() + rest[head.Length..];
        }
        // Bare "like" mid-sentence ("it could be like closer to") is left to the prompt: telling
        // filler from comparison needs both sides, and a wrong guess eats "sounds like really bad news".
        return Tidy(text);
    }

    // Collapse leftover whitespace and dangling commas. The lookahead is load-bearing: punctuation is
    // only pulled back onto the previous word when it ENDS something, or every leading-dot filename
    // gets glued to the word before ("check the .env file" → "check the.env file").
    static string Tidy(string text)
    {
        text = Regex.Replace(text, @"\s{2,}", " ");
        // A filler removed from between commas leaves both behind, and the pull-back below welds them
        // into ",,". Collapse here so any producer is covered.
        text = Regex.Replace(text, @",(\s*,)+", ",");
        text = Regex.Replace(text, @"\s+([,.!?])(?=\s|$)", "$1");
        text = Regex.Replace(text, @"^[,\s]+", "");
        return text.Trim();
    }

    // ---- Spoken lists

    // One family per list, so "first ... two ..." is not a sequence. Digits are there because the
    // model writes "1." itself often enough.
    static readonly (string[] Words, Regex Marker)[] Ordinals = new string[][]
    {
        ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"],
        ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"],
        Enumerable.Range(1, 10).Select(n => n.ToString()).ToArray(),
    }.Select(words => (words, new Regex(@"(?i)\b(" + string.Join("|", words) + @")(?:\s*[,:.](?=\s)|\s+is\b)\s*"))).ToArray();

    static readonly Regex OpensClauseBefore = new(@"(?i)(?:^|[.!?:,]\s|\band\s)$");

    // "One, X, two, Y, and three, Z" becomes a numbered list, one item per line. Why each condition
    // exists, with the real dictation behind it, is in CLAUDE.md and `SelfCheckText`. The last item
    // ends with its sentence, because nothing spoken marks where a list stops.
    public static string NumberedList(string text)
    {
        if (text.Contains('\n')) return text;
        foreach (var (family, regex) in Ordinals)
        {
            var markers = regex.Matches(text).ToList();
            int Value(Match marker) => Array.IndexOf(family, marker.Groups[1].Value.ToLowerInvariant());
            bool OpensClause(Match marker) => OpensClauseBefore.IsMatch(text[..marker.Index]);
            // Mid-clause, only a comma or colon marks a list: "this one is broken. Two, ..." is prose.
            bool CanStart(Match marker)
            {
                var numberEnd = marker.Groups[1].Index + marker.Groups[1].Length;
                return Value(marker) == 0 && (OpensClause(marker)
                    || text[numberEnd..(marker.Index + marker.Length)].Any(c => c is ',' or ':'));
            }
            for (var start = 0; start < markers.Count; start++)
            {
                if (!CanStart(markers[start])) continue;
                var chain = new List<Match> { markers[start] };
                foreach (var next in markers.Skip(start + 1))
                {
                    // "the first one is the Canary ... so one, how do I test it? Two, ..." counts
                    // from the "one" nearest the "two".
                    if (chain.Count == 1 && CanStart(next)) { chain = [next]; continue; }
                    if (!OpensClause(next)) continue;
                    if (Value(next) != chain.Count) break;
                    chain.Add(next);
                }
                if (chain.Count < 2) continue;

                var items = chain.Select((marker, i) =>
                {
                    var from = marker.Index + marker.Length;
                    var to = i + 1 < chain.Count ? chain[i + 1].Index : text.Length;
                    return text[from..to];
                }).ToList();
                // The last item stops at its first sentence end; the rest is prose again.
                var tail = "";
                if (Regex.Match(items[^1], @"[.!?](?=\s|$)") is { Success: true } end)
                {
                    tail = items[^1][(end.Index + 1)..];
                    items[^1] = items[^1][..(end.Index + 1)];
                }
                // A comma or "and" was only joining the items.
                items = items.Select(item => Regex.Replace(item, @"(?i)(?:[\s,]+|\band\b)+$", "")).ToList();
                if (!items.All(item => Elements(item).Any(IsLetter))) continue;
                // "One is X, two is Y, and three is Z." should not end only its last item with a stop.
                if (items.SkipLast(1).All(item => item.Length == 0 || ".!?".IndexOf(item[^1]) < 0) && items[^1].EndsWith('.'))
                    items[^1] = items[^1][..^1];

                var intro = text[..chain[0].Index].Trim();
                if (intro.EndsWith(',')) intro = intro[..^1];
                if (intro.Length > 0 && ".!?:".IndexOf(intro[^1]) < 0) intro += ":";
                var list = string.Join("\n", items.Select((item, i) =>
                {
                    var first = Elements(item)[0];
                    return $"{i + 1}. {first.ToUpperInvariant()}{item[first.Length..]}";
                }));
                var rest = tail.Trim();
                return (intro.Length == 0 ? "" : intro + "\n") + list
                    + (rest.Length == 0 ? "" : "\n\n" + NumberedList(rest));
            }
        }
        return text;
    }

    // ---- Rule-based fallback

    public static string RuleClean(string raw)
    {
        // Immediately repeated words ("the the" → "the"). Before the fillers: the filler pass consumes
        // the space it matched on, so "uh uh" keeps its second "uh" unless the pair collapsed first.
        var text = Regex.Replace(raw, @"(?i)\b(\w+)(\s+\1)+\b", "$1");
        text = StripFillers(text);
        if (text.Length > 0 && Elements(text)[0] is var first && IsLower(first))
            text = first.ToUpperInvariant() + text[first.Length..];
        return text;
    }
}
