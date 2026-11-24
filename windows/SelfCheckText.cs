using System.Text.Json;

namespace BisprBlow;

// Text checks that need no model: sentence casing, the low-touch invariant, what the dictionary
// learns from a hand-typed fix, voice commands, the field's own name, history, and numbered lists.
static class SelfCheckText
{
    public static void Run()
    {
        LowercaseSentences();
        LowTouchInvariant();
        Corrections();
        VoiceCommands();
        FieldLabel();
        HistoryRoundTrip();
        NumberedList();
    }

    // The three kinds of word that must survive lowercasing sentence starts: the failure that matters
    // is a capital eaten off a term the user put in the dictionary to get it spelled that way.
    static void LowercaseSentences()
    {
        string[] vocab = ["Kubernetes", "Bluejay", "Priya"];
        string Lower(string s) => LLMCleaner.LowercaseSentenceStarts(s, vocab);

        Check.Equal(Lower("Run the tests. Then commit."), "run the tests. then commit.");
        // "I" keeps its capital wherever it lands.
        Check.Equal(Lower("I think it works"), "I think it works");
        Check.Equal(Lower("I thought I did that."), "I thought I did that.");
        Check.Equal(Lower("I'm on it. I'll check."), "I'm on it. I'll check.");
        // Dictionary terms, acronyms, and internal capitals all keep theirs.
        Check.Equal(Lower("Kubernetes crashed again"), "Kubernetes crashed again");
        Check.Equal(Lower("Ship it. Kubernetes is fine."), "ship it. Kubernetes is fine.");
        Check.Equal(Lower("API returned a 500"), "API returned a 500");
        Check.Equal(Lower("GitHub is down"), "GitHub is down");
        Check.Equal(Lower("Priya said no"), "Priya said no");
        // Only sentence starts: a capital mid-sentence is the speaker's, not ours to take.
        Check.Equal(Lower("we told Alice and Bob"), "we told Alice and Bob");
        Check.Equal(Lower("Ask Sam about it"), "ask Sam about it");
        // A full stop inside quotes still ends the sentence; a comma does not start one.
        Check.Equal(Lower("He said \"go.\" Then he left."), "he said \"go.\" then he left.");
        Check.Equal(Lower("First, Then second"), "first, Then second");
        // Newlines open a sentence, and the text is otherwise returned byte for byte.
        Check.Equal(Lower("One thing\nTwo things"), "one thing\ntwo things");
        Check.Equal(Lower(""), "");
        Check.Equal(Lower("   Spaced   out  "), "   spaced   out  ");
    }

    // The coding path promises the model may only delete, repunctuate and respell; `RewordsContent`
    // makes that a fact. Every case here is one the few-shot demonstrates or the bench caught.
    static void LowTouchInvariant()
    {
        static bool Reworded(string cleaned, string raw, IReadOnlySet<string>? allowed = null) =>
            LLMCleaner.RewordsContent(cleaned, raw, allowed);

        // The low-touch few-shot outputs must all satisfy the invariant they teach.
        foreach (var (user, cleaned) in LLMCleaner.LowTouchFewShot)
        {
            var raw = user.Split('\n')[^1]["Transcript: ".Length..];
            Check.That(!Reworded(cleaned, raw), "few-shot violates the invariant: " + cleaned);
        }

        // Deleting fillers and rendering spoken symbols is what the path is for.
        Check.That(!Reworded("Run the tests with --verbose, and then commit.",
                             "run the the tests with um dash dash verbose and then uh commit"));
        Check.That(!Reworded("Check the .env file.", "check the dot env file"));
        // Numbers spoken as words, written as digits. "500s" keeps its plural.
        Check.That(!Reworded("Capping at 30 seconds, retry on 500s.",
                             "capping at thirty seconds retry on five hundreds"));
        // Two spoken words respelled as one compound.
        Check.That(!Reworded("A fixed backoff.", "a fixed back off"));
        // An identifier surviving verbatim is the whole point of the path.
        Check.That(!Reworded("The FLAG_RETRY_V2 flag is on for 10 percent of orgs.",
                             "the flag retry v2 flag is on for 10 percent of orgs"));

        // ...and the failures. A swapped word is the one LooksTruncated can never see: same length,
        // different meaning. Allowed only when the user handed us the term.
        Check.That(Reworded("Run it against the query.", "run it against the quarry"));
        Check.That(!Reworded("Run it against the query.", "run it against the quarry", new HashSet<string> { "query" }));
        Check.That(!Reworded("Push to prod.", "push to proud",
                             LLMCleaner.AllowedTerms([], ["prod", "db.query"])));
        // Reordering, which the prompt forbids and a length ratio cannot detect.
        Check.That(Reworded("Warm the index then cache the query.", "cache the query then warm the index"));
        // An invented connective: the model writing rather than cleaning.
        Check.That(Reworded("The spinner hangs. Furthermore, the session persists.",
                            "the spinner hangs the session persists"));
        // A compound may only be assembled from a pair at the scan head, never from two words at
        // opposite ends of the transcript.
        Check.That(Reworded("Backoff.", "back it off"));

        // And the reason this is gated on the coding path: a good polish-path rewrite fails it.
        Check.That(Reworded(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the session.",
            "okay so um i tested the new build and uh the login flow it's mostly working but i found "
            + "like two issues one is the spinner never goes away and two um when you log out it "
            + "doesn't clear the session"));
    }

    static bool SameWords(IEnumerable<string> actual, params string[] expected) => actual.SequenceEqual(expected);

    // Learning from a hand-typed fix, a new way to write to the dictionary, and the dictionary is the
    // one thing that can turn a correct transcript into a wrong one. Both halves are checked: what
    // counts as a correction, and what is worth keeping.
    static void Corrections()
    {
        static CorrectionWatcher.Correction? Fix(string before, string after) => CorrectionWatcher.Substitution(before, after);

        // One word swapped in place is the whole signal.
        var one = Fix("ask Devy about the deploy", "ask Devi about the deploy");
        Check.That(one?.Misheard == "Devy" && one?.Corrected == "Devi");

        // Punctuation belongs to the sentence, not to the word that goes in the dictionary.
        var punctuated = Fix("thanks, Devy.", "thanks, Devi.");
        Check.Equal(punctuated?.Corrected, "Devi");

        // Everything else is the user writing, and there is no telling which half of a rewrite was a
        // mishear. A second changed word, a word added, a word deleted: all null.
        Check.That(Fix("ask Devy about the deploy", "ask Devi about the release") == null);
        Check.That(Fix("ask Devy about it", "ask Devy about it today") == null);
        Check.That(Fix("ask Devy about it", "ask about it") == null);
        Check.That(Fix("same text", "same text") == null);

        // Worth keeping: a name the word list has never heard of, one edit away from what we wrote.
        Check.That(LLMCleaner.Learnable("Devy", "Devi"));
        Check.That(!LLMCleaner.Learnable("Bispr", "BisprBlow"));
        Check.That(LLMCleaner.Learnable("kubernetis", "Kubernetes"));

        // Not worth keeping: in all three the recognizer produced real English, so it got the word
        // right as far as the word list can tell. "code" to "Xcode" turned "just put a code fix for
        // it" into "just put a Xcode Vite for it", and it is indistinguishable from "prod" to "proud".
        Check.That(!LLMCleaner.Learnable("prod", "proud"));
        Check.That(!LLMCleaner.Learnable("code", "Xcode"));
        Check.That(!LLMCleaner.Learnable("shift", "Swift"));

        // Not a mishear at all: someone rewrote the word.
        Check.That(!LLMCleaner.Learnable("send", "cancel"));
        Check.That(!LLMCleaner.Learnable("Devi", "Devi"));

        // A word with a digit or an underscore is a variable name, not a dictated word.
        Check.That(!LLMCleaner.Learnable("userId", "user_id"));

        // Up to three words for up to three words, so a name split or joined is learned too.
        var joined = Fix("we use live kit here", "we use LiveKit here");
        Check.That(joined?.Misheard == "live kit" && joined?.Corrected == "LiveKit");
        Check.That(joined != null && SameWords(LLMCleaner.LearnedWords(joined), "LiveKit"));
        // A stretch that grew into other words is the user rewriting, and teaches nothing.
        var rewrite = Fix("send it to finance", "send it to the accountants");
        Check.That(rewrite != null && SameWords(LLMCleaner.LearnedWords(rewrite)));
        Check.That(Fix("meet me at noon", "meet you at dawn") == null);

        Check.That(SameWords(WisprImport.Corrections(
        [
            ("ask Devy about the deploy", "ask Devi about the deploy"),
            ("The plan is fine.", "the plan is fine"),
            ("ship it to prod", "ship it to proud"),
        ]), "Devi"));
        // A word that respells a dictation the user kept is not imported, nor one that only recases
        // it: "linear" in someone's maths is not the company.
        var harmless = LLMCleaner.Harmless(["Devi", "Kubernetes"], [], ["ask Devy about it", "Kubernetes is up"]);
        Check.That(SameWords(harmless, "Kubernetes"), string.Join(",", harmless));
        Check.That(LLMCleaner.Harmless(["Linear"], [], ["a linear fit"]).Count == 0);
    }

    // A voice command types only what follows the verb, and naming a field types nothing into it.
    static void VoiceCommands()
    {
        Check.Equal(VoiceCommand.TextToType("type looks good to me, ship it."), "looks good to me, ship it");
        Check.Equal(VoiceCommand.TextToType("Search Slack for metronome"), "metronome");
        Check.That(VoiceCommand.TextToType("click into the message box") == null);
        Check.That(VoiceCommand.TextToType("open the typescript file") == null);
    }

    // The field's own name is context too, and it leads: in an empty message box it is all there is.
    static void FieldLabel()
    {
        var terms = new AppContext("slack", "Slack", "Slack", "shipping this today", "Message #platform-team").DraftTerms;
        Check.That(terms.Contains("#platform-team"), string.Join(",", terms));
        Check.That(terms.Contains("shipping"), string.Join(",", terms));
    }

    // History is written and read by one JSON codec, and an empty history is indistinguishable from a
    // new install, so only a round trip catches a field the reader no longer understands.
    static void HistoryRoundTrip()
    {
        var entry = new DictationEntry(Guid.NewGuid(), new DateTime(2026, 9, 1, 12, 0, 0, DateTimeKind.Utc),
            "um so ship it", "Ship it.", "Claude", "Claude", "on-device", 1.5);
        var data = JsonSerializer.Serialize(new[] { entry }, HistoryStore.Json);
        var back = JsonSerializer.Deserialize<List<DictationEntry>>(data, HistoryStore.Json)!;
        Check.Equal(back.Count, 1);
        Check.Equal(back[0].Id, entry.Id);
        Check.Equal(back[0].Cleaned, entry.Cleaned);
        Check.Equal(back[0].Date, entry.Date);
        // The Mac reads the same file: camelCase keys, ISO-8601 date.
        Check.That(data.Contains("\"cleaned\":\"Ship it.\"") && data.Contains("2026-09-01T12:00:00Z"), data);
    }

    // Spoken enumerations become numbered lists. The first case is a real dictation, and so are most
    // of the false positives below.
    static void NumberedList()
    {
        static string List(string text) => LLMCleaner.NumberedList(text);

        Check.Equal(List("One is Agent Connection, two is Agent First Utterance, three is Agent "
                         + "Second Utterance, and four is Agent System."),
                    "1. Agent Connection\n2. Agent First Utterance\n3. Agent Second Utterance\n4. Agent System");
        Check.Equal(List("There are three things, one, I want to do this, two, I want to do that, "
                         + "and three, I want to also do that."),
                    "There are three things:\n1. I want to do this\n2. I want to do that\n3. I want to also do that");
        // The first number may sit mid-clause. This is the dictation that asked for the feature.
        Check.Equal(List("If you say something like one, I want this, two, I want that."),
                    "If you say something like:\n1. I want this\n2. I want that");
        Check.Equal(List("The first one is the Canary. So one, how do I test it? Two, what does the data look like?"),
                    "The first one is the Canary. So:\n1. How do I test it?\n2. What does the data look like?");
        // Ordinal words, a sentence per item, and prose after the last item. The polish few-shot turns
        // "one is ... two ..." into exactly this, so it is the shape the model path hands over.
        Check.Equal(List("I found two issues. First, the spinner never goes away. Second, logging out "
                         + "keeps the session. We should fix those before Friday."),
                    "I found two issues.\n1. The spinner never goes away.\n2. Logging out keeps the session.\n\nWe should fix those before Friday.");
        // Digits, the way a model writes them inline, and a full stop as the separator.
        Check.Equal(List("Plan: 1. fix the build. 2. ship it."), "Plan:\n1. Fix the build.\n2. Ship it.");
        Check.Equal(List("One. Fix the build. Two. Ship it."), "1. Fix the build.\n2. Ship it.");

        // Prose, all of it.
        string[] prose =
        [
            "I have two questions about the deploy.",
            "One more thing, can you check the logs?",
            "Bump it to version 1 2 3.",
            "When we go to steps one and two in the frontend, check the schema.",
            "For the agents that are implementing agents 1, 2, and 3, update the parameter.",
            "In the case of one, two, or three metrics, use one digital human.",
            "Testing, testing, one, two, three.",
            "One, two",
            "Two, I want that. Three, I want this.",
            "One, we're supposed to open agent settings.",
            "First, check the logs. Then restart it.",
            "This one is broken. Two, the build fails.",
            "We only need one. Two, the build fails.",
            "Upgrade to Gemini 2.5 Flash. 2.5 Flash is deprecated.",
        ];
        foreach (var text in prose) Check.That(List(text) == text, "became a list: " + text);
        // Already formatted, by the model or the speaker.
        Check.Equal(List("Steps:\n1. Build\n2. Ship"), "Steps:\n1. Build\n2. Ship");
    }
}
