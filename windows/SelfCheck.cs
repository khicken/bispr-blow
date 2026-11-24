using System.Runtime.CompilerServices;

namespace BisprBlow;

// `BisprBlow --self-check`: asserts the text logic that silently loses user words if it breaks, plus
// the input and cloud pieces that can be checked without a keyboard or a network. Every failure is
// printed, and the exit code is the number of them.
static class Check
{
    public static int Failures;

    public static void That(bool ok, [CallerArgumentExpression(nameof(ok))] string what = "",
                            [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (ok) return;
        Failures++;
        Console.WriteLine($"FAIL {System.IO.Path.GetFileName(file)}:{line}  {what}");
    }

    public static void Equal<T>(T actual, T expected, [CallerArgumentExpression(nameof(actual))] string what = "",
                                [CallerFilePath] string file = "", [CallerLineNumber] int line = 0)
    {
        if (EqualityComparer<T>.Default.Equals(actual, expected)) return;
        Failures++;
        Console.WriteLine($"FAIL {System.IO.Path.GetFileName(file)}:{line}  {what}\n  got:      {actual}\n  expected: {expected}");
    }
}

static partial class SelfCheck
{
    public static int Run()
    {
        // Each area owns its checks, in the file named after the Swift one.
        RunText();
        SelfCheckText.Run();
        SelfCheckInput.Run();
        SelfCheckCloud.Run();
        PillPlacement.SelfCheck();
        Console.WriteLine(Check.Failures == 0 ? "self-check passed" : $"self-check FAILED ({Check.Failures})");
        return Check.Failures;
    }

    // The text half: the guards, fillers, respeller and prompt plumbing, none of which need a model or
    // a window. `SelfCheckText` holds the rest of the text checks.
    static void RunText()
    {
        var raw = "okay so um i tested the new build and uh the login flow it's mostly working "
            + "but i found like two issues one is the spinner never goes away and two um when "
            + "you log out it doesn't clear the session so we should fix those before friday";

        // Trailing off, or coming back half-length, means content was dropped.
        Check.That(LLMCleaner.LooksTruncated("We should update the prompt and tailor...", raw));
        Check.That(LLMCleaner.LooksTruncated("I tested the new build and found two issues.", raw));
        // Elision mid-sentence, on a short dictation: "what's in this PR?" became "...".
        Check.That(LLMCleaner.LooksTruncated(
            "Yeah, wait... Can you see the link again?",
            "Yeah, wait, what's in this PR? Can you see the link again?"));
        // An ellipsis the speaker actually dictated is not the model's doing.
        Check.That(!LLMCleaner.LooksTruncated("Wait... never mind.", "wait ... never mind"));
        // A leaked reasoning trace, or the model answering instead of cleaning, runs long.
        Check.That(LLMCleaner.LooksTruncated(
            "Okay, let me tackle this. The user is dictating in Slack and wants the transcript "
            + "cleaned. First I should check for filler words, then apply the style rules for "
            + "chat, then make sure the question is preserved rather than answered.",
            "yeah wait what's in this PR"));
        Check.That(!LLMCleaner.LooksTruncated(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw));
        // Short dictations legitimately shrink a lot.
        Check.That(!LLMCleaner.LooksTruncated("Does it work?", "um does it uh does it work"));
        // Filler-stuffed speech is measured against the transcript with the fillers already gone.
        var stuffed = "um um so uh uh i think we should just ship it um today and see what breaks";
        Check.That(!LLMCleaner.LooksTruncated("We should ship it today and see what breaks.", stuffed));
        // A one-line summary of the same transcript still is.
        Check.That(LLMCleaner.LooksTruncated("Ship it today.", stuffed));

        Check.Equal(LLMCleaner.RuleClean("um the the tests uh pass"), "The tests pass");
        // Stacked fillers: the per-filler pass eats the space it matched on.
        Check.Equal(LLMCleaner.RuleClean("um um so uh uh we should just ship it"), "So we should just ship it");

        // Fillers the model left in its own output.
        Check.Equal(LLMCleaner.StripFillers("It was, like, really slow."), "It was really slow.");
        Check.Equal(LLMCleaner.StripFillers("Too high. Like, way too high."), "Too high. Way too high.");
        Check.Equal(LLMCleaner.StripFillers("It ships Friday, you know."), "It ships Friday.");
        // ...and the same words in their real senses are never touched.
        Check.Equal(LLMCleaner.StripFillers("I like it, and it looks like a bug, something like that."),
                    "I like it, and it looks like a bug, something like that.");
        Check.Equal(LLMCleaner.StripFillers("Do you know the answer?"), "Do you know the answer?");
        Check.Equal(LLMCleaner.StripFillers("Ship it and like the post."), "Ship it and like the post.");

        // Dictionary respelling is code, not the model.
        string[] vocab = ["Rohin", "Devi", "Claude", "worktree", "Kubernetes"];
        string Vocab(string text, IReadOnlyList<string> terms) => LLMCleaner.ApplyVocabulary(text, terms);
        // One edit away respells; exact letters in the wrong case take the dictionary casing.
        Check.Equal(Vocab("Ask Devy about it.", vocab), "Ask Devi about it.");
        Check.Equal(Vocab("ask claude to fix it", vocab), "ask Claude to fix it");
        // Nothing respells by sound. "Robin" is a real word, so it stays even beside a fixed "Devy".
        Check.Equal(Vocab("My name is Robin Devy.", vocab), "My name is Robin Devi.");
        string[] neighbours = ["Vercel", "frontend", "BisprBlow", "prod", "dev", "repo", "Claude", "worktree"];
        Check.Equal(Vocab("We move the front end from Versel.", neighbours), "We move the frontend from Vercel.");
        Check.Equal(Vocab("Ask Claude to open the Bisperblo works tree.", neighbours),
                    "Ask Claude to open the BisprBlow works tree.");
        Check.Equal(Vocab("a token bucket per api key", ["Vite", "API", "git"]), "a token bucket per API key");
        // Not every robin is Rohin and not every cloud is Claude.
        Check.Equal(Vocab("a robin in the garden", vocab), "a robin in the garden");
        Check.Equal(Vocab("push it to cloud storage", vocab), "push it to cloud storage");
        // A word the recognizer got RIGHT is never respelled, however close it sits to a term.
        Check.Equal(Vocab("just put a code fix for it", ["Xcode", "Vite"]), "just put a code fix for it");
        Check.Equal(Vocab("i sent you a gift", ["git"]), "i sent you a gift");
        Check.Equal(Vocab("hold shift and click", ["Swift"]), "hold shift and click");
        var plain = "open the cloud doc, then blow it up and get the hub working";
        Check.Equal(Vocab(plain, AppSettings.BuiltInWords), plain);
        Check.Equal(Vocab("ask claude in github", AppSettings.BuiltInWords), "ask Claude in GitHub");
        // A join leaves its neighbours alone.
        Check.Equal(Vocab("Says Blue Jay for all six.", ["bluejay", "git", "Vite"]), "Says bluejay for all six.");
        Check.Equal(Vocab("not just say Blue Jay everywhere", ["bluejay", "git", "Prettier"]),
                    "not just say bluejay everywhere");
        // An inflection of a term is the term: "docs" must not be respelled to "doc".
        Check.Equal(Vocab("can you run the docs page locally", ["doc", "dev", "Vite"]), "can you run the docs page locally");
        // The guard is the word list, so its absence must not be silent.
        Check.That(LLMCleaner.EnglishWords.Count > 0, "Resources/words.txt is missing: vocabulary respelling is unguarded");
        // Two words that concatenate into a term join.
        Check.Equal(Vocab("commit the work tree changes", vocab), "commit the worktree changes");
        // Short words never respell, and identifiers are untouchable.
        Check.Equal(Vocab("def main", ["dev"]), "def main");
        Check.Equal(Vocab("run FLAG_RETRY_V2 now", ["flagRetry"]), "run FLAG_RETRY_V2 now");

        // Recognizer homophones, from the real transcript "...merged into Maine".
        Check.Equal(Vocab("merge it into Maine.", []), "merge it into main.");
        Check.Equal(Vocab("rebase onto Maine", vocab), "rebase onto main");
        Check.Equal(Vocab("check the mail in the rain", vocab), "check the mail in the rain");

        // Heard-as: Windows has no rescorer, so an alias the user typed is respelled here, a word or a
        // phrase, any case, whole words only, even when it is real English.
        var heardAs = new Dictionary<string, List<string>>
        {
            ["Krishin"] = ["Christian"], ["BisprBlow"] = ["bisp for blow"],
        };
        string[] terms = ["Krishin", "BisprBlow"];
        Check.Equal(LLMCleaner.ApplyVocabulary("ask christian about it", terms, heardAs), "ask Krishin about it");
        Check.Equal(LLMCleaner.ApplyVocabulary("open Bisp For Blow now", terms, heardAs), "open BisprBlow now");
        Check.Equal(LLMCleaner.ApplyVocabulary("the christianity club", terms, heardAs), "the christianity club");
        Check.Equal(LLMCleaner.ApplyVocabulary("ask Christian", terms), "ask Christian");

        // The trailing period comes off when "End with a period" is off, but only a lone final full stop.
        Check.Equal(LLMCleaner.DroppingTrailingPeriod("Blue Jays."), "Blue Jays");
        Check.Equal(LLMCleaner.DroppingTrailingPeriod("Did the deploy work?"), "Did the deploy work?");
        Check.Equal(LLMCleaner.DroppingTrailingPeriod("Ship it. Then tag it"), "Ship it. Then tag it");
        Check.Equal(LLMCleaner.DroppingTrailingPeriod("tail app.log"), "tail app.log");
        // Bare "like" mid-sentence is deliberately left in.
        Check.Equal(LLMCleaner.StripFillers("the system tray or like the task bar"), "the system tray or like the task bar");

        // A leading-dot filename must survive the tidy pass.
        Check.Equal(LLMCleaner.StripFillers("check the .env file"), "check the .env file");
        Check.Equal(LLMCleaner.StripFillers("cd ../src and run it"), "cd ../src and run it");
        Check.Equal(LLMCleaner.StripFillers("open .gitignore and .env"), "open .gitignore and .env");
        // ...while punctuation that really is terminal still gets pulled back.
        Check.Equal(LLMCleaner.StripFillers("It was really slow ."), "It was really slow.");
        Check.Equal(LLMCleaner.StripFillers("Ship it , then commit"), "Ship it, then commit");

        // Interjections, and the stray full stop they left behind.
        Check.Equal(LLMCleaner.StripFillers("Oh. Uh. The login flow is broken."), "The login flow is broken.");
        Check.Equal(LLMCleaner.RuleClean("oh so i think we should ship it"), "So i think we should ship it");
        Check.Equal(LLMCleaner.StripFillers("It's fine. Oh and also the spinner hangs."), "It's fine. And also the spinner hangs.");
        // Both fillers go, not just the first: the marker counts as a word boundary.
        Check.Equal(LLMCleaner.RuleClean("um uh the tests pass"), "The tests pass");
        // "oh" inside a word is not an interjection.
        Check.Equal(LLMCleaner.StripFillers("Ohio and Ahmed shipped it"), "Ohio and Ahmed shipped it");
        // Deliberate phrase repetition collapsing on a short dictation trips the truncation guard.
        Check.That(LLMCleaner.LooksTruncated("blue Jays.", "Blue Jays, Blue Jays, Blue Jays"));
        // ...while legitimate short cleanups still clear the floor.
        Check.That(!LLMCleaner.LooksTruncated("Does it work?", "um does it uh does it work"));
        Check.That(!LLMCleaner.LooksTruncated("at 3", "at 2 actually 3"));

        // A filler between commas takes one comma with it, not neither.
        Check.Equal(LLMCleaner.StripFillers("Basically, um, we want the script"), "Basically, we want the script");
        Check.Equal(LLMCleaner.StripFillers("a smaller model decide, oh, this seems incoherent"),
                    "a smaller model decide, this seems incoherent");
        // After a word no clause ends on, neither comma was real.
        Check.Equal(LLMCleaner.StripFillers("the format is, um, standard"), "the format is standard");
        Check.Equal(LLMCleaner.StripFillers("because, uh, it's slow"), "because it's slow");
        // A filler that brought its own comma takes it along.
        Check.Equal(LLMCleaner.StripFillers("Update the uh, this cookbook, Doc."), "Update the this cookbook, Doc.");

        Check.Equal(LLMCleaner.Sanitize("```\nhello\n```", fallback: "x"), "hello");
        Check.Equal(LLMCleaner.Sanitize("", fallback: "fallback"), "fallback");

        // No em dash reaches the cursor, spaced or not.
        Check.Equal(LLMCleaner.Sanitize("both — I don't know", fallback: ""), "both, I don't know");
        Check.Equal(LLMCleaner.Sanitize("both—I don't know", fallback: ""), "both, I don't know");
        Check.That(!LLMCleaner.LowTouchFewShot.Any(shot => shot.Cleaned.Contains('—')));
        Check.That(!LLMCleaner.FewShot.Any(shot => shot.Cleaned.Contains('—')));

        // The recognizer marks a pause with an ellipsis; it is stripped at the source, which keeps
        // `LooksTruncated`'s elision check armed.
        Check.Equal(Transcriber.WithoutPauseMarks("You check blue jet bottles again to see... If we already offloaded this work."),
                    "You check blue jet bottles again to see If we already offloaded this work.");
        Check.Equal(Transcriber.WithoutPauseMarks("wait … never mind"), "wait never mind");
        Check.Equal(Transcriber.WithoutPauseMarks("so anyway..."), "so anyway");
        // Two dots are left alone: a spoken relative path is not a pause.
        Check.Equal(Transcriber.WithoutPauseMarks("cd ../src"), "cd ../src");
        Check.That(LLMCleaner.LooksTruncated(
            "I tested the build and...",
            Transcriber.WithoutPauseMarks("i tested the build and uh the login flow was "
                                          + "mostly working... but the spinner never stopped")));

        // Verbatim from history: 45 words in, 24 out, the whole second half deleted, and it PASSED
        // LooksTruncated because 24 clears 55% of the filler-stripped 40 by two words.
        var halfLost = "In the text section, we should also add a formatting option to like reduce "
            + "commas, like then, I don't know, or do like punctuation. So if it's on, it would be "
            + "like one of my punctuation. I I don't know, justice system problem or something.";
        var firstHalfOnly = "In the text section, we should also add a formatting option to like "
            + "reduce commas, like then, I don't know, or do like punctuation.";
        Check.That(!LLMCleaner.LooksTruncated(firstHalfOnly, halfLost));
        Check.That(LLMCleaner.LosesContent(firstHalfOnly, halfLost));
        // A correct cleanup of the same transcript keeps the content and must not be rejected.
        Check.That(!LLMCleaner.LosesContent(
            "In the text section, we should also add a formatting option to reduce commas, or adjust "
            + "punctuation. So if it's on, it would adjust my punctuation. I don't know, just a "
            + "system problem or something.", halfLost));
        // Filler-heavy speech compressed hard is not content loss.
        Check.That(!LLMCleaner.LosesContent(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw));
        // Too short to judge.
        Check.That(!LLMCleaner.LosesContent("Does it work?", "um does it uh does it work"));

        // Verbatim, and it reproduced every run: the last sentence simply gone, at 88% of the words
        // and ~90% content recall, so both ratios pass it. Position is what sees it.
        var tailLost = "Date filtering is very limited, and there is some redundant types at the "
            + "bottom. The custom line should be a, should show a modal that will show, like, a date "
            + "selection and time selection. So not only it'll be days, but also time. Like, let's "
            + "say I want to see the past 12 hours. It should be really easy to do that.";
        var withoutTail = "Date filtering is very limited, and there are some redundant types at the "
            + "bottom. The custom line should show a modal with a date and time selection, so not "
            + "only days but also time. Let's say I want to see the past 12 hours.";
        Check.That(!LLMCleaner.LooksTruncated(withoutTail, tailLost));
        Check.That(!LLMCleaner.LosesContent(withoutTail, tailLost));
        Check.That(LLMCleaner.DropsTail(withoutTail, tailLost));
        // The same cleanup with that sentence kept is correct and must ship.
        Check.That(!LLMCleaner.DropsTail(withoutTail + " It should be really easy to do that.", tailLost));
        // A respelling of the final word is not a deletion, in either direction.
        var respelled = "check the work tree before you rebase, and then run the whole suite again "
            + "against the staging database and the local work tree";
        Check.That(!LLMCleaner.DropsTail(
            "Check the worktree before you rebase, then run the whole suite again against the "
            + "staging database and the local worktree.", respelled));
        // Short dictations are not judged.
        Check.That(!LLMCleaner.DropsTail("Ship it today.", "um so i think we should just ship it um today yeah"));
        // A whole sentence gone from the middle or the end of a short dictation.
        var permissions = "Also, I don't understand why you're asking me to approve commands. Um, I have "
            + "bypass permissions on.";
        Check.That(LLMCleaner.DropsSentence(
            "also, I don't understand why you're asking me to approve commands", permissions));
        Check.Equal(LLMCleaner.Rejection("also, I don't understand why you're asking me to approve commands",
                                         permissions, false, LLMCleaner.NoTerms), LLMCleaner.DroppedSentence);
        Check.That(LLMCleaner.DropsSentence(
            "that's so chill. yeah, just say that we have gotten beta permission to test out the app",
            "That's so chill. Yeah, just say that we have gotten, um, beta permission to test out "
            + "the app. That's pretty exciting."));
        Check.That(!LLMCleaner.DropsSentence(permissions, permissions));
        // A self-correction across sentences keeps most of its words, and a short one is not judged.
        Check.That(!LLMCleaner.DropsSentence("Let's ship it Thursday.", "Let's ship it Friday. No, actually Thursday."));
        // Every demonstration the model is shown must pass, or the prompt teaches a rejection.
        foreach (var (user, cleaned) in LLMCleaner.FewShot.Concat(LLMCleaner.LowTouchFewShot))
        {
            var shotRaw = user.Split('\n')[^1]["Transcript: ".Length..];
            Check.That(!LLMCleaner.DropsSentence(cleaned, shotRaw), "few-shot drops a sentence: " + cleaned);
        }
        // Verbatim from history, and it shipped: a 149-word dictation lost its whole closing sentence
        // and every guard stayed silent. Two holes: presence rather than position, and the prefix loosener.
        var ramble = "Also, yeah, the dedication needs to be really worked on. I don't know why words keep getting "
            + "cut off. I think it's the LLM being too aggressive. Like, it should be aggressive when doing "
            + "a bunch of intense cleanup. Like, uh, like, the goal is we're trying to transcribe to real "
            + "text and identify intent. But if we say some, like, chopped phrase, just to fill in a larger "
            + "phrase, such as, um, like 2nd is, which makes no sense out of context, but the user actually "
            + "wants to say 2nd is to fill in a phrase. Like, that should be fine. But if we say, but if "
            + "the LLM can understand the intent, like, oh, there's a lot of, like, there's a contradiction "
            + "in the paragraph, then the LLM should clean that up. There's stutters or, like, filler words "
            + "that aren't needed, then that's for the cleanup too.";
        var rambleCut = "also, the dedication needs to be really worked on. I don't know why words keep getting cut "
            + "off. I think it's the LLM being too aggressive. it should be aggressive when doing a bunch "
            + "of intense cleanup. the goal is we're trying to transcribe to real text and identify intent. "
            + "but if we say some chopped phrase, just to fill in a larger phrase, such as, like 2nd is, "
            + "which makes no sense out of context, but the user actually wants to say 2nd is to fill in a "
            + "phrase. that should be fine. but if we say, but if the LLM can understand the intent, "
            + "there's a lot of there's a contradiction in the paragraph, then the LLM should clean that up";
        Check.That(!LLMCleaner.LooksTruncated(rambleCut, ramble));
        Check.That(!LLMCleaner.LosesContent(rambleCut, ramble));
        Check.That(LLMCleaner.DropsTail(rambleCut, ramble));
        // The morphology the prefix loosener exists for still passes: one character of slack.
        Check.That(!LLMCleaner.DropsTail(
            "Check the snap region before you rebase, then run the whole suite again against the "
            + "staging database and the local snap region.",
            "check the snap regions before you rebase, and then run the whole suite again "
            + "against the staging database and the local snap regions"));

        // A dictation short enough to skip the model ships `RuleClean`, so `RuleClean` is what has to
        // keep the user's words. "Second is." was reported twice.
        Check.That(LLMCleaner.VerbatimWords >= 8);
        Check.Equal(LLMCleaner.RuleClean("Second is."), "Second is.");
        Check.Equal(LLMCleaner.RuleClean("Hello?"), "Hello?");
        Check.Equal(LLMCleaner.RuleClean("Well, right."), "Well, right.");
        // It is still a cleanup, not a pass-through: fillers and doubled words go.
        Check.That(LLMCleaner.RuleClean("Update the uh, this cookbook, Doc.").Contains("this cookbook"));
        Check.That(!LLMCleaner.RuleClean("um does it uh does it work").Contains("uh"));

        // Verbatim from history: the recognizer chose "four" over "for" by sound and formatted it as a
        // numeral, and the guard then threw away the only stage that could fix it.
        Check.That(!LLMCleaner.RewordsContent("Just keep the best for and afterwards text.", "Just keep the best 4 and afterwards text."));
        Check.That(!LLMCleaner.RewordsContent("push to dev, not prod", "push 2 dev not prod"));
        // The exemption is a closed table, not a licence to rewrite numbers.
        Check.That(LLMCleaner.RewordsContent("keep the best bits", "keep the best 4"));
        Check.That(LLMCleaner.RewordsContent("retry many times", "retry 3 times"));
        // A real number the model spelled out stays legal in the other direction too.
        Check.That(!LLMCleaner.RewordsContent("retry three times", "retry 3 times"));

        // The floor has to clear the cleanup latency observed in the log, 280-729ms.
        Check.That(LLMCleaner.DeadlineMs(0) > 729);
        Check.That(LLMCleaner.DeadlineMs(47) > 729);
        // A long dictation still gets proportionally more.
        Check.That(LLMCleaner.DeadlineMs(240) > 1510);
        Check.Equal(LLMCleaner.DeadlineMs(100_000), 2500L);
        // Accurate resolves to a model several times the size, so it gets several times the budget.
        foreach (var words in new[] { 0, 12, 240, 100_000 })
            Check.That(LLMCleaner.DeadlineMs(words, careful: true) > LLMCleaner.DeadlineMs(words) * 2);

        // Recognizer bias comes from the words on screen, and a plain lowercase word in a code buffer
        // is the one a general model gets wrong ("query" heard as "quarry").
        var draftTerms = new AppContext("Code", "Code", "db.ts",
            "const rows = await db.query(sql) // just make sure the cache and the query are warm").DraftTerms.ToList();
        Check.That(draftTerms.Contains("query") && draftTerms.Contains("cache"));
        Check.That(draftTerms.Any(t => t.Contains("db.query")));
        Check.That(draftTerms.FindIndex(t => t.Contains("db.query")) < draftTerms.IndexOf("query"));
        Check.That(!draftTerms.Contains("just") && !draftTerms.Contains("make") && !draftTerms.Contains("the"));

        // The /no_think switch goes on its own LINE. Glued to the transcript it reads as part of it,
        // and the low-touch rules promise every spoken word survives.
        var switched = LLMCleaner.WithThinkingOff(
            [new ChatMessage("user", "App: Terminal (coding)\nTranscript: revert the last commit")], "Qwen3-0.6B-Q8_0");
        var content = switched[0].Content;
        Check.That(content.EndsWith("\n/no_think"), "the switch must sit on its own line");
        Check.That(content.Contains("Transcript: revert the last commit\n"), "the transcript line must survive untouched");
        // Not a Qwen3 model, no switch: it would be a literal instruction to anything else.
        Check.Equal(LLMCleaner.WithThinkingOff([new ChatMessage("user", "hi")], "llama-3.2-3b")[0].Content, "hi");
        // Small and careful families resolve the ids this app installs.
        Check.Equal(LLMCleaner.Pick(["Qwen3-0.6B-Q8_0", "Qwen3-1.7B-Q8_0"], Cleanup.Fast), "Qwen3-0.6B-Q8_0");
        Check.Equal(LLMCleaner.Pick(["Qwen3-0.6B-Q8_0", "Qwen3-1.7B-Q8_0"], Cleanup.Accurate), "Qwen3-1.7B-Q8_0");
    }
}
