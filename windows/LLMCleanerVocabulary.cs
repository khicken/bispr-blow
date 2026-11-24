using System.IO;
using System.Text.RegularExpressions;

namespace BisprBlow;

public partial class LLMCleaner
{
    // Homophones the recognizer picks the wrong side of, keyed lowercase. The swap is
    // unconditional, so "the coast of Maine" becomes "main" too. Keep it short.
    static readonly Dictionary<string, string> Misheard = new() { ["maine"] = "main" };

    // The gate `near` answers to: a word list, filtered to the lengths `near` can fire on. macOS reads
    // its own /usr/share/dict/words; Windows has none, so build.ps1 fetches the same list (FreeBSD's
    // web2) to Resources/words.txt beside the exe.
    // Empty when the file is missing, which restores the old false positives rather than disabling
    // respelling. `WarmUpAsync` builds it so the first dictation does not spend its deadline here.
    public static IReadOnlySet<string> EnglishWords => englishWords.Value;

    static readonly Lazy<IReadOnlySet<string>> englishWords = new(() =>
    {
        var path = Path.Combine(System.AppContext.BaseDirectory, "Resources", "words.txt");
        if (!File.Exists(path))
        {
            Log.Line("vocabulary guard: Resources/words.txt missing, respelling unguarded");
            return new HashSet<string>();
        }
        try { return File.ReadLines(path).Select(w => w.Trim()).Where(w => Len(w) >= 4).Select(w => w.ToLowerInvariant()).ToHashSet(); }
        catch (Exception e)
        {
            Log.Line($"vocabulary guard: words.txt unreadable ({e.Message}), respelling unguarded");
            return new HashSet<string>();
        }
    });

    // Deterministic dictionary respelling, after the model, because at 0.6B-1.7B the model does not
    // do it ("Robin Devy" shipped uncorrected with both names in the prompt) and the rules path
    // has no model at all. Tiered, because a wrong swap corrupts the user's words:
    //
    // - exact: same letters, wrong case → take the dictionary casing ("claude" → "Claude").
    // - near: edit distance ≤1 (≤2 from eight letters), four letters minimum — "Devy" → "Devi"
    //   but never "def" → "dev".
    // - joined: two words that concatenate into a term ("work tree" → "worktree").
    //
    // No sound-alike tier: one by phonetic key made 0 fixes over 500 real dictations and only ever
    // rewrote the real words beside a `near` fix ("front end from Versel" → "frontend prod Vercel").
    //
    // The fourth tier, ahead of all three, is `Misheard`, for words the dictionary cannot express
    // safely: "main" as an entry would make `near` rewrite "mail", "rain", "pain" and "gain" too.
    // And ahead of that, heard-as: on the Mac the recognizer's rescorer takes those aliases from the
    // audio, but Windows has no rescorer, so a word or phrase the user typed as a mishear of a term
    // is that term here, even when it is a real English word.
    public static string ApplyVocabulary(string text, IReadOnlyList<string> vocabulary,
                                         IReadOnlyDictionary<string, List<string>>? heardAs = null)
    {
        text = ApplyHeardAs(text, vocabulary, heardAs);
        var terms = vocabulary.Where(t => t.Length > 0 && !t.Contains(' ')).ToList();

        // Words and the separators between them, so reassembly preserves the original spacing.
        var words = new List<string>();
        var seps = new List<string> { "" };
        foreach (var ch in Elements(text))
        {
            if (IsSpace(ch))
            {
                if (words.Count == seps.Count) seps.Add(ch); else seps[^1] += ch;
            }
            else
            {
                if (words.Count < seps.Count) words.Add(ch); else words[^1] += ch;
            }
        }
        if (words.Count == seps.Count) seps.Add("");

        static string Bare(string w) => w.Trim('"', '\'', ')', ']', '}', '”', '’', '(', '[', '{', '“', '‘', '.', ',', '!', '?', ';', ':');
        // Identifiers, paths, numbers: not the recognizer mishearing a name, leave them alone.
        static bool PlainWord(string b) =>
            b.Length > 0 && Elements(b) is var e && e.All(IsLetter) && !e.Skip(1).Any(IsUpper);
        void Replace(int i, string term)
        {
            var w = words[i];
            var b = Bare(w);
            var at = w.IndexOf(b, StringComparison.Ordinal);
            if (at < 0) return;
            words[i] = w[..at] + term + w[(at + b.Length)..];
        }

        Tier TierOf(string b, string term)
        {
            var w = b.ToLowerInvariant();
            var t = term.ToLowerInvariant();
            if (w == t) return Tier.Exact;
            if (Len(w) < 3 || Len(t) < 3) return Tier.None;
            // An inflection of a term IS the term, heard correctly. "docs" is one edit from "doc" and is
            // not in the word list, so `near` respelled it, destroying the plural. Both directions, since
            // the dictionary may hold either form.
            if (w == t + "s" || w == t + "es" || t == w + "s" || t == w + "es") return Tier.None;
            // `near` fires on spelling alone, so it must never overwrite a word the recognizer got right:
            // Levenshtein("code", "xcode") == 1 turned "code" into "Xcode". Across the shipped
            // dictionary "git" ate gift/gist/grit, "Vite" ate site/cite/bite, "Swift" ate shift,
            // "linter" ate liner/linger/linker, "Claude" ate clause.
            // Being real English is the discriminator, not being long: "Devy" → "Devi" is four letters
            // and is exactly what the dictionary is for.
            if (Len(w) >= 4 && !EnglishWords.Contains(w)
                && Levenshtein(w, t) <= (Math.Max(Len(w), Len(t)) >= 8 ? 2 : 1)) return Tier.Near;
            return Tier.None;
        }

        var i = 0;
        while (i < words.Count)
        {
            var b = Bare(words[i]);
            if (!PlainWord(b)) { i++; continue; }
            if (Misheard.TryGetValue(b.ToLowerInvariant(), out var fix))
            {
                Replace(i, fix);
                i++;
                continue;
            }
            // Two words that join into one term: "work tree" → "worktree".
            if (i + 1 < words.Count && words[i].EndsWith(Bare(words[i]), StringComparison.Ordinal))
            {
                var b2 = Bare(words[i + 1]);
                if (PlainWord(b2) && terms.FirstOrDefault(t => TierOf(b + b2, t) == Tier.Exact) is { } joined)
                {
                    var tail = string.Concat(Elements(words[i + 1]).Skip(Len(b2)));
                    Replace(i, joined);
                    words[i] += tail;
                    words.RemoveAt(i + 1);
                    seps.RemoveAt(i + 1);
                    i++;
                    continue;
                }
            }
            (Tier Tier, string Term)? best = null;
            foreach (var term in terms)
            {
                var t = TierOf(b, term);
                if ((int)t > (best is { } leader ? (int)leader.Tier : 0)) best = (t, term);
            }
            if (best is { Tier: Tier.Exact } exact && exact.Term.Any(char.IsUpper) && b != exact.Term)
                Replace(i, exact.Term);
            else if (best is { Tier: Tier.Near } near)
                Replace(i, near.Term);
            i++;
        }
        return string.Concat(seps.Zip(words.Append(""), (s, w) => s + w));
    }

    enum Tier { None, Near, Exact }

    // A heard-as alias, word or phrase and any case, whole words only, is its term. Longest first, so
    // "bisp for blow" wins over a shorter alias inside it. The term takes the dictionary's casing.
    static string ApplyHeardAs(string text, IReadOnlyList<string> vocabulary,
                               IReadOnlyDictionary<string, List<string>>? heardAs)
    {
        if (heardAs is null) return text;
        var aliases = heardAs
            .Select(p => (Term: vocabulary.FirstOrDefault(v => v.Equals(p.Key, StringComparison.OrdinalIgnoreCase)), p.Value))
            .Where(p => p.Term != null)
            .SelectMany(p => p.Value.Select(alias => (Alias: alias.Trim(), Term: p.Term!)))
            .Where(p => p.Alias.Length > 0)
            .OrderByDescending(p => p.Alias.Length);
        foreach (var (alias, term) in aliases)
        {
            var phrase = string.Join(@"\s+", alias.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Regex.Escape));
            text = Regex.Replace(text, @"(?<![\p{L}\p{N}])" + phrase + @"(?![\p{L}\p{N}])", _ => term, RegexOptions.IgnoreCase);
        }
        return text;
    }

    // Soundex-style consonant classes, first letter included (so C and K agree), vowels reset the
    // run. "christian" and "krishin" land one edit apart.
    static string PhoneticKey(string s)
    {
        var output = new System.Text.StringBuilder();
        char? last = null;
        foreach (var ch in Elements(s))
        {
            char? code;
            switch (ch)
            {
                case "b" or "f" or "p" or "v": code = '1'; break;
                case "c" or "g" or "j" or "k" or "q" or "s" or "x" or "z": code = '2'; break;
                case "d" or "t": code = '3'; break;
                case "l": code = '4'; break;
                case "m" or "n": code = '5'; break;
                case "r": code = '6'; break;
                case "h" or "w": continue;
                default: last = null; continue;
            }
            if (code != last) output.Append(code);
            last = code;
        }
        return output.ToString();
    }

    static bool WordLike(string text) => Elements(text).All(c => IsLetter(c) || c is "'" or "-");

    // Whether a word the user retyped by hand is worth keeping in the dictionary. Same discriminator
    // as the respeller: being real English. An entry for a real word licenses `near` on its
    // neighbours, which is how "code" turned "just put a code fix for it" into "just put a Xcode Vite
    // for it". BOTH words are tested against the word list — an edit away from real English is as
    // likely to be a change of mind as a mishear — so the app learns only from what the recognizer
    // plainly invented ("Devy", "kubernetis"). The pair also has to be a plausible mishear: same
    // rough length, and either one edit apart or sharing a phonetic key.
    public static bool Learnable(string misheard, string corrected)
    {
        var heard = misheard.ToLowerInvariant();
        var fixedWord = corrected.ToLowerInvariant();
        if (heard == fixedWord
            || Len(corrected) < 3 || Len(corrected) > 30
            || !WordLike(corrected) || !WordLike(misheard)
            || EnglishWords.Contains(fixedWord)
            // Four letters is where `EnglishWords` starts, so a shorter heard word is one the list
            // has no opinion about — and an opinion is the whole basis for learning here.
            || Len(heard) < 4 || EnglishWords.Contains(heard))
            return false;
        return SoundsAlike(heard, fixedWord);
    }

    // Same rough length, and either two edits apart or one apart in sound: a mishear, not a rewrite.
    static bool SoundsAlike(string heard, string fixedWord) =>
        Math.Abs(Len(heard) - Len(fixedWord)) <= 3
            && (Levenshtein(heard, fixedWord) <= 2 || Levenshtein(PhoneticKey(heard), PhoneticKey(fixedWord)) <= 1);

    // The dictionary words a fix teaches. One word for one word is `Learnable`'s call. A longer fix
    // ("live kit" → "LiveKit", "Abhivit Pulapaka" → "Abhived Pulapaka") must pass the same shape test
    // across the whole stretch, and teaches only the new words the word list has never heard of: a
    // real word needs no teaching.
    internal static List<string> LearnedWords(CorrectionWatcher.Correction fix)
    {
        var heard = fix.Misheard.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var fixedWords = fix.Corrected.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (heard.Length == 1 && fixedWords.Length == 1)
            return Learnable(fix.Misheard, fix.Corrected) ? [fix.Corrected] : [];
        if (!heard.Concat(fixedWords).All(WordLike)
            || !SoundsAlike(string.Concat(heard).ToLowerInvariant(), string.Concat(fixedWords).ToLowerInvariant()))
            return [];
        var heardWords = heard.Select(w => w.ToLowerInvariant()).ToHashSet();
        return fixedWords.Where(w => Len(w) >= 3 && !EnglishWords.Contains(w.ToLowerInvariant())
                                     && !heardWords.Contains(w.ToLowerInvariant())).ToList();
    }

    // Keeps only the words that never put a word into one of `dictations` that was not already there,
    // recasing included: those are text the user kept, so a word that changes one will do the same
    // to the next. Repeats because dropping a word can hand its matches to another candidate.
    public static List<string> Harmless(IEnumerable<string> words, IReadOnlyList<string> vocabulary, IEnumerable<string> dictations)
    {
        var kept = words.ToList();
        var lines = dictations.ToList();
        while (true)
        {
            var keptKeys = kept.Select(w => w.ToLowerInvariant()).ToHashSet();
            var withKept = vocabulary.Concat(kept).ToList();
            var respelled = new string[lines.Count];
            Parallel.For(0, lines.Count, index => respelled[index] = ApplyVocabulary(lines[index], withKept));
            var blamed = new HashSet<string>();
            for (var n = 0; n < lines.Count; n++)
            {
                if (respelled[n] == lines[n]) continue;
                var said = SpokenWords(lines[n]).ToHashSet();
                blamed.UnionWith(SpokenWords(respelled[n]).Where(w => !said.Contains(w))
                    .Select(w => w.ToLowerInvariant()).Where(keptKeys.Contains));
            }
            if (blamed.Count == 0) return kept;
            kept.RemoveAll(w => blamed.Contains(w.ToLowerInvariant()));
        }
    }

    static IEnumerable<string> SpokenWords(string line) =>
        line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(w =>
        {
            var start = 0;
            var end = w.Length;
            while (start < end && char.IsPunctuation(w[start])) start++;
            while (end > start && char.IsPunctuation(w[end - 1])) end--;
            return w[start..end];
        });

    static int Levenshtein(string a, string b)
    {
        var x = Elements(a);
        var y = Elements(b);
        if (x.Length == 0 || y.Length == 0) return Math.Max(x.Length, y.Length);
        var row = Enumerable.Range(0, y.Length + 1).ToArray();
        for (var i = 0; i < x.Length; i++)
        {
            var prev = row[0];
            row[0] = i + 1;
            for (var j = 0; j < y.Length; j++)
            {
                var cost = x[i] == y[j] ? prev : Math.Min(prev, Math.Min(row[j], row[j + 1])) + 1;
                prev = row[j + 1];
                row[j + 1] = cost;
            }
        }
        return row[y.Length];
    }
}
