import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// `BluejayWispr --self-check`: asserts the text logic that silently loses user words if
/// it breaks. `precondition`, not `assert` — release builds strip asserts.
enum SelfCheck {
    static func run() {
        let raw = "okay so um i tested the new build and uh the login flow it's mostly working "
            + "but i found like two issues one is the spinner never goes away and two um when "
            + "you log out it doesn't clear the session so we should fix those before friday"

        // Trailing off, or coming back half-length, means content was dropped.
        precondition(LLMCleaner.looksTruncated("We should update the prompt and tailor...", raw: raw))
        precondition(LLMCleaner.looksTruncated("I tested the new build and found two issues.", raw: raw))
        // Elision mid-sentence, on a short dictation — "what's in this PR?" became "...".
        precondition(LLMCleaner.looksTruncated(
            "Yeah, wait... Can you see the link again?",
            raw: "Yeah, wait, what's in this PR? Can you see the link again?"))
        // An ellipsis the speaker actually dictated is not the model's doing.
        precondition(!LLMCleaner.looksTruncated("Wait... never mind.", raw: "wait ... never mind"))
        // A leaked reasoning trace, or the model answering instead of cleaning, runs long.
        precondition(LLMCleaner.looksTruncated(
            "Okay, let me tackle this. The user is dictating in Slack and wants the transcript "
            + "cleaned. First I should check for filler words, then apply the style rules for "
            + "chat, then make sure the question is preserved rather than answered.",
            raw: "yeah wait what's in this PR"))
        precondition(!LLMCleaner.looksTruncated(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw: raw))
        // Short dictations legitimately shrink a lot.
        precondition(!LLMCleaner.looksTruncated("Does it work?", raw: "um does it uh does it work"))
        // Filler-stuffed speech is measured against the transcript with the fillers already gone,
        // so a tight cleanup of a third-filler transcript is not truncation. Reported by the bench:
        // qwen3-0.6b cleaned this correctly and the guard threw the result away.
        let stuffed = "um um so uh uh i think we should just ship it um today and see what breaks"
        precondition(!LLMCleaner.looksTruncated(
            "We should ship it today and see what breaks.", raw: stuffed))
        // A one-line summary of the same transcript still is.
        precondition(LLMCleaner.looksTruncated("Ship it today.", raw: stuffed))

        precondition(LLMCleaner.ruleClean("um the the tests uh pass") == "The tests pass")
        // Stacked fillers: the per-filler pass eats the space it matched on, so "uh uh" kept its
        // second "uh" until the repeated-word collapse moved ahead of it.
        precondition(LLMCleaner.ruleClean("um um so uh uh we should just ship it")
                     == "So we should just ship it")

        // Fillers the model left in its own output. Reported live: "like" and "uh" reaching the
        // cursor, from a reply the truncation guard accepted, so cleanup ran and simply missed them.
        precondition(LLMCleaner.stripFillers("It was, like, really slow.") == "It was really slow.")
        precondition(LLMCleaner.stripFillers("Too high. Like, way too high.") == "Too high. Way too high.")
        precondition(LLMCleaner.stripFillers("It ships Friday, you know.") == "It ships Friday.")
        // ...and the same words in their real senses are never touched. Losing one of these is
        // worse than leaving every filler in.
        precondition(LLMCleaner.stripFillers("I like it, and it looks like a bug, something like that.")
                     == "I like it, and it looks like a bug, something like that.")
        precondition(LLMCleaner.stripFillers("Do you know the answer?") == "Do you know the answer?")
        precondition(LLMCleaner.stripFillers("Ship it and like the post.") == "Ship it and like the post.")

        // Dictionary respelling is code, not the model: at 0.6B the prompt's vocabulary line went
        // unapplied on every real dictation ("Christian Parik" shipped as-is with both names in
        // the prompt), so the substitution runs after the model, where it cannot be ignored.
        let vocab = ["Krishin", "Parikh", "Claude", "worktree", "Kubernetes"]
        // One edit away respells; exact letters in the wrong case take the dictionary casing.
        precondition(LLMCleaner.applyVocabulary("Ask Parik about it.", vocabulary: vocab)
                     == "Ask Parikh about it.")
        precondition(LLMCleaner.applyVocabulary("ask claude to fix it", vocabulary: vocab)
                     == "ask Claude to fix it")
        // A sound-alike is corrected only beside another dictionary hit — a misheard name arrives
        // as a misheard pair, and the pair is the evidence...
        precondition(LLMCleaner.applyVocabulary("My name is Christian Parik.", vocabulary: vocab)
                     == "My name is Krishin Parikh.")
        // ...and the evidence must be a word the pass itself respelled. An exact dictionary hit
        // is a word the recognizer got RIGHT, and with a dictionary of common dev terms it fires
        // on nearly every dictation: "per api key" shipped as "Vite API git" on a real one when
        // exact matches licensed their neighbors. The case fix on "api" still applies.
        precondition(LLMCleaner.applyVocabulary("a token bucket per api key",
                                                vocabulary: ["Vite", "API", "git"])
                     == "a token bucket per API key")
        // ...so the same sound-alikes alone are never touched: not every christian is Krishin and
        // not every cloud is Claude.
        precondition(LLMCleaner.applyVocabulary("the christian church", vocabulary: vocab)
                     == "the christian church")
        precondition(LLMCleaner.applyVocabulary("push it to cloud storage", vocabulary: vocab)
                     == "push it to cloud storage")
        // A word the recognizer got RIGHT is never respelled, however close it sits to a term.
        // "just put a code fix for it" shipped as "just put a Xcode Vite for it" on a real
        // dictation: levenshtein("code", "xcode") is 1, and correcting it licensed the phonetic
        // tier on its neighbour. Being real English is what disqualifies it — not being long,
        // because "Parik" above is five letters and must still respell.
        precondition(LLMCleaner.applyVocabulary("just put a code fix for it",
                                                vocabulary: ["Xcode", "Vite"])
                     == "just put a code fix for it")
        precondition(LLMCleaner.applyVocabulary("i sent you a gift",
                                                vocabulary: ["git"]) == "i sent you a gift")
        precondition(LLMCleaner.applyVocabulary("hold shift and click",
                                                vocabulary: ["Swift"]) == "hold shift and click")
        // The guard is the word list, so its absence must not be silent.
        precondition(!LLMCleaner.englishWords.isEmpty,
                     "/usr/share/dict/words is missing — vocabulary respelling is unguarded")
        // Two words that concatenate into a term join.
        precondition(LLMCleaner.applyVocabulary("commit the work tree changes", vocabulary: vocab)
                     == "commit the worktree changes")
        // Short words never respell: "def" in a terminal is a Python keyword, not a mishearing
        // of "dev". Identifiers and anything with an inner capital are likewise untouchable.
        precondition(LLMCleaner.applyVocabulary("def main", vocabulary: ["dev"]) == "def main")
        precondition(LLMCleaner.applyVocabulary("run FLAG_RETRY_V2 now", vocabulary: ["flagRetry"])
                     == "run FLAG_RETRY_V2 now")

        // Recognizer homophones. The real transcript: "branches that all need to be merged into
        // Maine". The swap is whole-word and runs with an empty dictionary too, since it is not
        // a dictionary entry — and it must not drag the rhymes along with it, which is exactly
        // what putting "main" in the dictionary would have done at edit distance 1.
        precondition(LLMCleaner.applyVocabulary("merge it into Maine.", vocabulary: [])
                     == "merge it into main.")
        precondition(LLMCleaner.applyVocabulary("rebase onto Maine", vocabulary: vocab)
                     == "rebase onto main")
        precondition(LLMCleaner.applyVocabulary("check the mail in the rain", vocabulary: vocab)
                     == "check the mail in the rain")

        // The trailing period comes off when "End with a period" is off — but only a lone final
        // full stop. Question marks carry meaning, inner sentence periods stay, and a trailing
        // identifier keeps its dots.
        precondition(LLMCleaner.droppingTrailingPeriod("Blue Jays.") == "Blue Jays")
        precondition(LLMCleaner.droppingTrailingPeriod("Did the deploy work?") == "Did the deploy work?")
        precondition(LLMCleaner.droppingTrailingPeriod("Ship it. Then tag it") == "Ship it. Then tag it")
        precondition(LLMCleaner.droppingTrailingPeriod("tail app.log") == "tail app.log")
        // Bare "like" mid-sentence is deliberately left in. "or like the task bar" is filler and
        // "and like the post" is a verb, and only what sits before the conjunction tells them
        // apart, so this one goes to the prompt rather than to a regex.
        precondition(LLMCleaner.stripFillers("the system tray or like the task bar")
                     == "the system tray or like the task bar")

        // A leading-dot filename must survive the tidy pass. This ran on every dictation and glued
        // the dot to the word before it, undoing the one thing the coding path exists to protect —
        // and it read in the bench as the model "missing '.env'" when the model had it right.
        precondition(LLMCleaner.stripFillers("check the .env file") == "check the .env file")
        precondition(LLMCleaner.stripFillers("cd ../src and run it") == "cd ../src and run it")
        precondition(LLMCleaner.stripFillers("open .gitignore and .env") == "open .gitignore and .env")
        // ...while punctuation that really is terminal still gets pulled back.
        precondition(LLMCleaner.stripFillers("It was really slow .") == "It was really slow.")
        precondition(LLMCleaner.stripFillers("Ship it , then commit") == "Ship it, then commit")

        // Interjections nothing used to look for, and the stray full stop they left behind.
        precondition(LLMCleaner.stripFillers("Oh. Uh. The login flow is broken.")
                     == "The login flow is broken.")
        precondition(LLMCleaner.ruleClean("oh so i think we should ship it")
                     == "So i think we should ship it")
        precondition(LLMCleaner.stripFillers("It's fine. Oh and also the spinner hangs.")
                     == "It's fine. And also the spinner hangs.")
        // Both fillers go, not just the first: the marker counts as a word boundary.
        precondition(LLMCleaner.ruleClean("um uh the tests pass") == "The tests pass")
        // "oh" inside a word is not an interjection.
        precondition(LLMCleaner.stripFillers("Ohio and Ahmed shipped it") == "Ohio and Ahmed shipped it")
        // Deliberate phrase repetition collapsing on a short dictation now trips the truncation
        // guard — "Blue Jays, Blue Jays, Blue Jays" reached the cursor as "blue Jays." with every
        // guard silent, because under 12 words nothing was checked at all.
        precondition(LLMCleaner.looksTruncated("blue Jays.", raw: "Blue Jays, Blue Jays, Blue Jays"))
        // ...while legitimate short cleanups still clear the floor: heavy filler stripping and a
        // resolved self-correction both land at or above half the spoken words.
        precondition(!LLMCleaner.looksTruncated("Does it work?", raw: "um does it uh does it work"))
        precondition(!LLMCleaner.looksTruncated("at 3", raw: "at 2 actually 3"))

        // A filler between commas takes one comma with it, not neither — "decide,," reached the
        // cursor twice from real dictations before this collapsed.
        precondition(LLMCleaner.stripFillers("Basically, um, we want the script")
                     == "Basically, we want the script")
        precondition(LLMCleaner.stripFillers("a smaller model decide, oh, this seems incoherent")
                     == "a smaller model decide, this seems incoherent")

        precondition(LLMCleaner.sanitize("```\nhello\n```", fallback: "x") == "hello")
        precondition(LLMCleaner.sanitize("", fallback: "fallback") == "fallback")

        // No em dash reaches the cursor, spaced or not. The few-shot demonstrates the comma, so
        // this is the backstop rather than the mechanism.
        precondition(LLMCleaner.sanitize("both — I don't know", fallback: "") == "both, I don't know")
        precondition(LLMCleaner.sanitize("both—I don't know", fallback: "") == "both, I don't know")
        precondition(!LLMCleaner.lowTouchFewShot.contains { $0.1.contains("—") })
        precondition(!LLMCleaner.fewShot.contains { $0.1.contains("—") })

        checkLowercaseSentences()
        // The recognizer marks a pause with an ellipsis. Verbatim from history — this reached the
        // cursor, and while it sat in the transcript it also switched off looksTruncated's elision
        // check, so a cleanup that trailed off would have been accepted on the same dictation.
        precondition(Transcriber.withoutPauseMarks(
            "You check blue jet bottles again to see... If we already offloaded this work.")
            == "You check blue jet bottles again to see If we already offloaded this work.")
        precondition(Transcriber.withoutPauseMarks("wait … never mind") == "wait never mind")
        precondition(Transcriber.withoutPauseMarks("so anyway...") == "so anyway")
        // Two dots are left alone: a spoken relative path is not a pause.
        precondition(Transcriber.withoutPauseMarks("cd ../src") == "cd ../src")
        // ...and with the marker gone, the guard it used to disarm is armed again.
        precondition(LLMCleaner.looksTruncated(
            "I tested the build and...",
            raw: Transcriber.withoutPauseMarks("i tested the build and uh the login flow was "
                                              + "mostly working... but the spinner never stopped")))

        // Verbatim from history: 45 words in, 24 out, the whole second half deleted — and it PASSED
        // looksTruncated, because 24 clears 55% of the filler-stripped 40 by two words. A length
        // ratio cannot see which half the survivors came from.
        let halfLost = "In the text section, we should also add a formatting option to like reduce "
            + "commas, like then, I don't know, or do like punctuation. So if it's on, it would be "
            + "like one of my punctuation. I I don't know, justice system problem or something."
        let firstHalfOnly = "In the text section, we should also add a formatting option to like "
            + "reduce commas, like then, I don't know, or do like punctuation."
        precondition(!LLMCleaner.looksTruncated(firstHalfOnly, raw: halfLost), "the old guard let this through")
        precondition(LLMCleaner.losesContent(firstHalfOnly, raw: halfLost), "half the dictation is gone")
        // A correct cleanup of the same transcript keeps the content and must not be rejected.
        precondition(!LLMCleaner.losesContent(
            "In the text section, we should also add a formatting option to reduce commas, or adjust "
            + "punctuation. So if it's on, it would adjust my punctuation. I don't know, just a "
            + "system problem or something.", raw: halfLost))
        // Filler-heavy speech compressed hard is not content loss: every content word is still there.
        precondition(!LLMCleaner.losesContent(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw: raw))
        // Too short to judge — one dropped word would swing the ratio past any threshold.
        precondition(!LLMCleaner.losesContent("Does it work?", raw: "um does it uh does it work"))

        // Verbatim, and it reproduced every run: the last sentence simply gone, at 88% of the words
        // and ~90% content recall, so both ratios above pass it. Position is what sees it.
        let tailLost = "Date filtering is very limited, and there is some redundant types at the "
            + "bottom. The custom line should be a, should show a modal that will show, like, a date "
            + "selection and time selection. So not only it'll be days, but also time. Like, let's "
            + "say I want to see the past 12 hours. It should be really easy to do that."
        let withoutTail = "Date filtering is very limited, and there are some redundant types at the "
            + "bottom. The custom line should show a modal with a date and time selection, so not "
            + "only days but also time. Let's say I want to see the past 12 hours."
        precondition(!LLMCleaner.looksTruncated(withoutTail, raw: tailLost), "88% of the words")
        precondition(!LLMCleaner.losesContent(withoutTail, raw: tailLost), "~90% content recall")
        precondition(LLMCleaner.dropsTail(withoutTail, raw: tailLost), "the last sentence is gone")
        // The same cleanup with that sentence kept is correct and must ship.
        precondition(!LLMCleaner.dropsTail(withoutTail + " It should be really easy to do that.",
                                           raw: tailLost))
        // A respelling of the final word is not a deletion, in either direction.
        let respelled = "check the work tree before you rebase, and then run the whole suite again "
            + "against the staging database and the local work tree"
        precondition(!LLMCleaner.dropsTail(
            "Check the worktree before you rebase, then run the whole suite again against the "
            + "staging database and the local worktree.", raw: respelled))
        // Short dictations are not judged: the last word is as likely to be a discarded "yeah".
        precondition(!LLMCleaner.dropsTail("Ship it today.", raw: "um so i think we should just ship "
                                           + "it um today yeah"))

        checkLowTouchInvariant()

        // Verbatim from history: the recognizer chose "four" over "for" by sound and its number
        // formatting made it a numeral, and the guard then threw away the only stage that could
        // see the sentence and fix it.
        precondition(!LLMCleaner.rewordsContent("Just keep the best for and afterwards text.",
                                                raw: "Just keep the best 4 and afterwards text."))
        precondition(!LLMCleaner.rewordsContent("push to dev, not prod", raw: "push 2 dev not prod"))
        // The exemption is a closed table, not a licence to rewrite numbers.
        precondition(LLMCleaner.rewordsContent("keep the best bits", raw: "keep the best 4"))
        precondition(LLMCleaner.rewordsContent("retry many times", raw: "retry 3 times"))
        // A real number the model spelled out stays legal in the other direction too.
        precondition(!LLMCleaner.rewordsContent("retry three times", raw: "retry 3 times"))

        // The floor has to clear the cleanup latency actually observed in the log — 280-729ms, only
        // weakly tied to length. A 400ms base sat inside that spread, so the deadline coin-flipped
        // and threw away the model's punctuation on ~30% of dictations to save 14-47ms.
        precondition(LLMCleaner.deadlineMs(words: 0) > 729)
        precondition(LLMCleaner.deadlineMs(words: 47) > 729)
        // ...and a long dictation still gets proportionally more, since cost does grow with length:
        // measured on qwen3-0.6b, 0.20s for twelve words against 1.51s for two hundred and forty.
        precondition(LLMCleaner.deadlineMs(words: 240) > 1510)
        precondition(LLMCleaner.deadlineMs(words: 100_000) == 2500)
        // Accurate resolves to a model several times the size, so it has to get several times the
        // budget at every length. A careful model on the fast budget is not more accurate — it
        // misses the deadline and ships the same rule-cleaned text, only later.
        for words in [0, 12, 240, 100_000] {
            precondition(LLMCleaner.deadlineMs(words: words, careful: true)
                            > LLMCleaner.deadlineMs(words: words) * 2)
        }

        // Theme migration. "Bluejay" was the only light option there was, so storing it says
        // nothing about wanting light; "Bluejay World" was a real choice and survives.
        precondition(AppSettings.appearance(stored: nil) == .system)
        precondition(AppSettings.appearance(stored: "Bluejay") == .system)
        precondition(AppSettings.appearance(stored: "Bluejay World") == .world)
        precondition(AppSettings.appearance(stored: "Dark") == .dark)
        // The joke theme still has to be legible, so it names a real face — a missing one makes
        // Font.custom fall back silently and the theme just looks like it forgot.
        precondition(Appearance.unhinged.palette.fontNames.contains { NSFont(name: $0, size: 12) != nil },
                     "no installed face among \(Appearance.unhinged.palette.fontNames)")

        let settings = AppSettings.shared
        let before = settings.dictionary
        settings.addDictionaryWords(["  worktree ", "Kubernetes", "worktree", ""])
        precondition(settings.dictionary.filter { $0 == "worktree" }.count == 1)
        precondition(settings.dictionary.contains("Kubernetes"))
        settings.dictionary = before

        // Recognizer bias comes from the words already on screen, and a plain lowercase word in a
        // code buffer is exactly the one a general language model gets wrong — "query" heard as
        // "quarry". So plain domain words have to survive, identifiers have to lead, and words
        // common in any English must not crowd them out of a capped list.
        let terms = AppContext(
            bundleID: "com.microsoft.vscode", appName: "Code", windowTitle: "db.ts",
            draft: "const rows = await db.query(sql) // just make sure the cache and the query are warm"
        ).draftTerms
        precondition(terms.contains("query") && terms.contains("cache"), "\(terms)")
        precondition(terms.contains(where: { $0.contains("db.query") }), "\(terms)")
        precondition(terms.firstIndex(where: { $0.contains("db.query") })! < terms.firstIndex(of: "query")!)
        precondition(!terms.contains("just") && !terms.contains("make") && !terms.contains("the"), "\(terms)")

        // A section left out of a sidebar group just disappears from the nav, silently.
        precondition(DashboardView.Section.groups.flatMap(\.items) == DashboardView.Section.allCases)

        checkAnchors()
        checkCorrections()
        checkFieldLabel()
        checkShortcuts()
        checkGestures()
        checkAccurateResolution()

        print("self-check passed")
    }

    /// Lowercase sentence starts, and the three kinds of word that must survive it. The failure
    /// that matters is a capital getting eaten off a term the user put in the dictionary
    /// precisely so it would be spelled that way.
    /// Accurate resolving to the same model as Fast is the whole trigger for offering the download,
    /// and it is invisible from outside: `pick` falls through to the first installed model rather
    /// than failing, so the setting moves and the writing does not change.
    private static func checkAccurateResolution() {
        let fastOnly = ["Qwen3-0.6B-MLX-4bit"]
        precondition(LLMCleaner.pick(from: fastOnly, for: .accurate)
            == LLMCleaner.pick(from: fastOnly, for: .fast), "Accurate should collapse onto Fast here")

        let both = ["Qwen3-0.6B-MLX-4bit", "Qwen3-1.7B-MLX-8bit"]
        precondition(LLMCleaner.pick(from: both, for: .fast) == "Qwen3-0.6B-MLX-4bit")
        // The explicit "qwen3-1.7b" entry earning its place: without it the generic "qwen" matches
        // the 0.6b and the two modes collapse even with both models on disk.
        precondition(LLMCleaner.pick(from: both, for: .accurate) == "Qwen3-1.7B-MLX-8bit")

        precondition(LLMCleaner.pick(from: [], for: .accurate) == nil)
    }

    private static func checkLowercaseSentences() {
        let vocab = ["Kubernetes", "Bluejay", "Priya"]
        func lower(_ s: String) -> String { LLMCleaner.lowercaseSentenceStarts(s, keeping: vocab) }

        precondition(lower("Run the tests. Then commit.") == "run the tests. then commit.")
        // "I" keeps its capital wherever it lands. This case used to assert the opposite, which
        // is how "i thought I did that" reached a real dictation looking like a typo.
        precondition(lower("I think it works") == "I think it works")
        precondition(lower("I thought I did that.") == "I thought I did that.")
        precondition(lower("I'm on it. I'll check.") == "I'm on it. I'll check.")
        // Dictionary terms, acronyms, and internal capitals all keep theirs.
        precondition(lower("Kubernetes crashed again") == "Kubernetes crashed again")
        precondition(lower("Ship it. Kubernetes is fine.") == "ship it. Kubernetes is fine.")
        precondition(lower("API returned a 500") == "API returned a 500")
        precondition(lower("GitHub is down") == "GitHub is down")
        precondition(lower("Priya said no") == "Priya said no")
        // Only sentence starts: a capital mid-sentence is the speaker's, not ours to take.
        precondition(lower("we told Kaleb and Sam") == "we told Kaleb and Sam")
        precondition(lower("Ask Sam about it") == "ask Sam about it")
        // A full stop inside quotes still ends the sentence; a comma does not start one.
        precondition(lower("He said \"go.\" Then he left.") == "he said \"go.\" then he left.")
        precondition(lower("First, Then second") == "first, Then second")
        // Newlines open a sentence, and the text is otherwise returned byte for byte.
        precondition(lower("One thing\nTwo things") == "one thing\ntwo things")
        precondition(lower("") == "")
        precondition(lower("   Spaced   out  ") == "   spaced   out  ")
    }

    /// The coding path promises the model may only delete, repunctuate and respell, and
    /// `rewordsContent` is what makes that a fact rather than a hope. Every case here is one the
    /// prompt's own few-shot demonstrates, or one the bench caught the model doing.
    private static func checkLowTouchInvariant() {
        let reworded = LLMCleaner.rewordsContent

        // The three low-touch few-shot outputs must all satisfy the invariant they teach.
        for (user, cleaned) in LLMCleaner.lowTouchFewShot {
            let raw = String(user.split(separator: "\n").last!.dropFirst("Transcript: ".count))
            precondition(!reworded(cleaned, raw, []), "few-shot violates the invariant: \(cleaned)")
        }

        // Deleting fillers and rendering spoken symbols is what the path is for.
        precondition(!reworded("Run the tests with --verbose, and then commit.",
                               "run the the tests with um dash dash verbose and then uh commit", []))
        precondition(!reworded("Check the .env file.", "check the dot env file", []))
        // Numbers spoken as words, written as digits. "500s" keeps its plural.
        precondition(!reworded("Capping at 30 seconds, retry on 500s.",
                               "capping at thirty seconds retry on five hundreds", []))
        // Two spoken words respelled as one compound.
        precondition(!reworded("A fixed backoff.", "a fixed back off", []))
        // An identifier surviving verbatim is the whole point of the path.
        precondition(!reworded("The FLAG_RETRY_V2 flag is on for 10 percent of orgs.",
                               "the flag retry v2 flag is on for 10 percent of orgs", []))

        // ...and the failures. A swapped word is the one looksTruncated can never see: same length,
        // different meaning. Allowed only when the user handed us the term.
        precondition(reworded("Run it against the query.", "run it against the quarry", []))
        precondition(!reworded("Run it against the query.", "run it against the quarry", ["query"]))
        precondition(!reworded("Push to prod.", "push to proud",
                               LLMCleaner.allowedTerms(vocabulary: [], draftTerms: ["prod", "db.query"])))
        // Reordering, which the prompt forbids and a length ratio cannot detect.
        precondition(reworded("Warm the index then cache the query.",
                              "cache the query then warm the index", []))
        // An invented connective — the model writing rather than cleaning.
        precondition(reworded("The spinner hangs. Furthermore, the session persists.",
                              "the spinner hangs the session persists", []))
        // A compound may only be assembled from a pair at the scan head, never from two words
        // grabbed from opposite ends of the transcript.
        precondition(reworded("Backoff.", "back it off", []))

        // And the reason this is gated on the coding path: a perfectly good polish-path rewrite
        // fails it, by design. Applying it everywhere would reject almost every dictation.
        precondition(reworded(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the session.",
            "okay so um i tested the new build and uh the login flow it's mostly working but i found "
            + "like two issues one is the spinner never goes away and two um when you log out it "
            + "doesn't clear the session", []))
    }

    /// Where a release lands the pill. Everything here is in screen coordinates, bottom-left
    /// origin, against a `visibleFrame`-shaped rect.
    /// Learning from a hand-typed fix, which is a new way to write to the dictionary — and the
    /// dictionary is the one thing in the app that can turn a correct transcript into a wrong one.
    /// Both halves are checked: what counts as a correction at all, and what is worth keeping.
    private static func checkCorrections() {
        func fix(_ before: String, _ after: String) -> CorrectionWatcher.Correction? {
            CorrectionWatcher.substitution(from: before, to: after)
        }

        // One word swapped in place is the whole signal.
        let one = fix("ask Parik about the deploy", "ask Parikh about the deploy")
        precondition(one?.misheard == "Parik" && one?.corrected == "Parikh")

        // Punctuation belongs to the sentence, not to the word that goes in the dictionary.
        let punctuated = fix("thanks, Parik.", "thanks, Parikh.")
        precondition(punctuated?.corrected == "Parikh", "\(punctuated?.corrected ?? "nil")")

        // Everything else is the user writing, and there is no way to tell which half of a rewrite
        // was a mishear. A second changed word, a word added, a word deleted: all nil.
        precondition(fix("ask Parik about the deploy", "ask Parikh about the release") == nil)
        precondition(fix("ask Parik about it", "ask Parik about it today") == nil)
        precondition(fix("ask Parik about it", "ask about it") == nil)
        precondition(fix("same text", "same text") == nil)

        // Worth keeping: a name the word list has never heard of, one edit away from what we wrote.
        precondition(LLMCleaner.learnable(misheard: "Parik", corrected: "Parikh"))
        precondition(LLMCleaner.learnable(misheard: "Bispr", corrected: "BisprBlow") == false)
        precondition(LLMCleaner.learnable(misheard: "kubernetis", corrected: "Kubernetes"))

        // Not worth keeping. In all three the recognizer produced real English, so it got the word
        // right as far as the word list can tell and the edit is as likely to be a change of mind
        // as a fix. "code" → "Xcode" is the pair that turned "just put a code fix for it" into
        // "just put a Xcode Vite for it", and it is indistinguishable from "prod" → "proud" without
        // knowing what the speaker meant.
        precondition(LLMCleaner.learnable(misheard: "prod", corrected: "proud") == false)
        precondition(LLMCleaner.learnable(misheard: "code", corrected: "Xcode") == false)
        precondition(LLMCleaner.learnable(misheard: "shift", corrected: "Swift") == false)

        // Not a mishear at all: someone rewrote the word.
        precondition(LLMCleaner.learnable(misheard: "send", corrected: "cancel") == false)
        precondition(LLMCleaner.learnable(misheard: "Parikh", corrected: "Parikh") == false)

        // A word with a digit or an underscore in it is a variable name, not a dictated word — the
        // recognizer never produced it, so nothing here should be storing it.
        precondition(LLMCleaner.learnable(misheard: "userId", corrected: "user_id") == false)
    }

    /// The field's own name is context too, and it leads: in an empty message box it is the only
    /// thing there is, which is exactly when the draft has nothing to offer.
    private static func checkFieldLabel() {
        let terms = AppContext(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            windowTitle: "Slack", draft: "shipping this today",
            fieldLabel: "Message #platform-team"
        ).draftTerms
        precondition(terms.contains("#platform-team"), "\(terms)")
        precondition(terms.contains("shipping"), "\(terms)")
    }

    private static func checkAnchors() {
        let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
        let pill = CGSize(width: 122, height: 48)
        typealias Anchor = RecordingPillController.Anchor
        precondition(Anchor.containing(NSPoint(x: 60, y: 440), in: screen) == .leftCentre)
        precondition(Anchor.containing(NSPoint(x: 1300, y: 440), in: screen) == .rightCentre)
        precondition(Anchor.containing(NSPoint(x: 676, y: 20), in: screen) == .bottomCentre)
        // Released in open space: nil, so the pill stays where it was instead of being flung to
        // whichever target happened to be closest.
        precondition(Anchor.containing(NSPoint(x: 676, y: 440), in: screen) == nil)
        // The lit target is the landing spot, so a point inside a zone must be near its landing.
        precondition(Anchor.leftCentre.zone(in: screen)
            .contains(NSPoint(x: 60, y: 440)))
        precondition(Anchor.leftCentre.landing(in: screen).size == CGSize(width: 48, height: 122))
        precondition(Anchor.leftCentre.origin(size: pill, in: screen) == NSPoint(x: 4, y: 415))
        precondition(Anchor.rightCentre.origin(size: pill, in: screen) == NSPoint(x: 1226, y: 415))
        precondition(Anchor.bottomCentre.origin(size: pill, in: screen) == NSPoint(x: 615, y: 0))
        // The bar hugs its panel's edge, and `rotation` maps that local edge onto the parked screen
        // edge. Get this pair out of step and the sliver drifts to the middle of the panel or, worse,
        // to the side facing away from the bezel.
        precondition(Anchor.bottomCentre.contentAlignment == .bottom)
        precondition(Anchor.leftCentre.contentAlignment == .top
                     && Anchor.rightCentre.contentAlignment == .top)
        // A side-anchored pill is the same bar turned 90°, so its panel is the transpose. If these
        // ever disagree the panel clips the pill or claims mouse events beside it.
        let flat = PillView.size(for: .idle, anchor: .bottomCentre)
        precondition(PillView.size(for: .idle, anchor: .leftCentre)
            == CGSize(width: flat.height, height: flat.width))
        precondition(Anchor.leftCentre.isVertical && !Anchor.bottomCentre.isVertical)
    }

    /// Bindings are serialized into UserDefaults and rendered as key caps in Settings, so a
    /// break here either loses the user's shortcut or shows them the wrong one.
    private static func checkShortcuts() {
        let combo = Shortcut(trigger: .key(kVK_ANSI_D),
                             flags: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        let mouse4 = Shortcut(trigger: .mouse(3))

        precondition(Shortcut.fn.display == "fn")
        precondition(Shortcut.escape.display == "esc")
        precondition(combo.display == "⌃⌥D")
        precondition(mouse4.display == "Mouse 4")  // button 3 is what every UI calls mouse 4
        precondition(Shortcut(trigger: .key(kVK_Space)).display == "Space")

        // Modifiers have to match exactly, minus the noise bits macOS adds.
        precondition(combo.matches(keyCode: kVK_ANSI_D,
                                   flags: [.maskControl, .maskAlternate, .maskNonCoalesced]))
        precondition(!combo.matches(keyCode: kVK_ANSI_D, flags: [.maskControl]))
        precondition(!combo.matches(keyCode: kVK_ANSI_D, flags: [.maskControl, .maskAlternate, .maskShift]))
        precondition(!combo.matches(keyCode: kVK_ANSI_F, flags: [.maskControl, .maskAlternate]))
        // A standalone modifier matches on its keycode whatever else is held — that is what
        // makes "hold fn" work while shift is down, and it is what the fn-only monitor did.
        precondition(Shortcut.fn.matches(keyCode: kVK_Function, flags: [.maskSecondaryFn, .maskShift]))
        precondition(!Shortcut.fn.matches(keyCode: kVK_Shift, flags: [.maskSecondaryFn]))
        precondition(mouse4.matches(mouseButton: 3) && !mouse4.matches(mouseButton: 2))
        // Only an fn binding may take over the macOS Globe key.
        precondition(Shortcut.fn.usesFn && !combo.usesFn)
        precondition(Shortcut(trigger: .key(kVK_ANSI_D),
                              flags: CGEventFlags.maskSecondaryFn.rawValue).usesFn)

        // Recording a binding: hold the combination, let go, and what was down is what is saved.
        // Both halves are from real reports — ⌃⇧G recorded as ⇧G, and ⌃⇧ not recording at all.
        //
        // The flags on these keyDowns are deliberately wrong, because that is the bug: the
        // recorder swallows each modifier's flagsChanged, so the window server never learns the
        // modifier went down and the flags it stamps on the following keyDown are missing it —
        // the modifier held *first* being the one that vanishes.
        func record(_ steps: [(CGEventType, Int?, CGEventFlags)]) -> Shortcut? {
            var state = ShortcutMonitor.CaptureState()
            for (type, code, flags) in steps {
                if case .record(let shortcut) = ShortcutMonitor.captureStep(
                    type: type, keyCode: code, mouseButton: nil, flags: flags, state: &state) {
                    return shortcut
                }
            }
            return nil
        }
        // ⌃⇧G, with the keyDown carrying only shift, then everything released.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.keyDown, kVK_ANSI_G, [.maskShift]),
                             (.keyUp, kVK_ANSI_G, [.maskShift]),
                             (.flagsChanged, kVK_Shift, [.maskControl]),
                             (.flagsChanged, kVK_Control, [])])?.display == "⌃⇧G")
        // Nothing is recorded until the last key is up: the same sequence, stopped early.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.keyDown, kVK_ANSI_G, [.maskShift]),
                             (.keyUp, kVK_ANSI_G, [.maskShift])]) == nil)
        // Modifiers with no key at all is a binding in its own right — hold ⌃⇧ to talk. It has
        // no keycode, so it can only be recorded on release, which is why the model is release-
        // to-finalize rather than first-key-wins.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.flagsChanged, kVK_Shift, [.maskControl]),
                             (.flagsChanged, kVK_Control, [])])?.display == "⌃⇧")
        // A lone modifier stays a keycode, so left ⌃ and right ⌃ remain different bindings.
        precondition(record([(.flagsChanged, kVK_Function, [.maskSecondaryFn]),
                             (.flagsChanged, kVK_Function, [])]) == Shortcut.fn)
        precondition(record([(.flagsChanged, kVK_RightControl, [.maskControl]),
                             (.flagsChanged, kVK_RightControl, [])])?.display == "Right ⌃")
        // A plain key with no modifiers at all.
        precondition(record([(.keyDown, kVK_ANSI_G, []), (.keyUp, kVK_ANSI_G, [])])?.display == "G")

        // A modifiers-only binding fires when its set completes and stops when it breaks — the
        // set is the whole gesture, so it matches exactly rather than as a subset.
        let ctrlShift = Shortcut(trigger: .modifiers,
                                 flags: CGEventFlags([.maskControl, .maskShift]).rawValue)
        precondition(ctrlShift.matches(modifiers: [.maskControl, .maskShift]))
        precondition(!ctrlShift.matches(modifiers: [.maskControl]))
        precondition(!ctrlShift.matches(modifiers: [.maskControl, .maskShift, .maskCommand]))
        precondition(!ctrlShift.matches(modifiers: []))
        // It carries no keycode, so the key path must never claim it as well.
        precondition(!ctrlShift.matches(keyCode: kVK_Control, flags: [.maskControl, .maskShift]))
        precondition(Shortcut(trigger: .modifiers,
                              flags: CGEventFlags([.maskSecondaryFn, .maskShift]).rawValue).usesFn)

        // Round trip: bindings live in UserDefaults as JSON.
        let saved = ["pushToTalk": [Shortcut.fn, combo], "handsFree": [mouse4]]
        let data = try! JSONEncoder().encode(saved)
        precondition(try! JSONDecoder().decode([String: [Shortcut]].self, from: data) == saved)

        // fn stays the shipped push-to-talk default; Esc stays cancel.
        precondition(ShortcutAction.pushToTalk.defaults == [.fn])
        precondition(ShortcutAction.cancel.defaults == [.escape])

        // Assigning a binding steals it: two actions on one key means one never fires.
        let stolen = AppSettings.adding(mouse4, to: .cancel, in: saved)
        precondition(stolen["handsFree"] == [])
        precondition(stolen["cancel"] == [mouse4])
        precondition(stolen["pushToTalk"] == [.fn, combo])
        // Re-adding the same binding to the same action must not duplicate it.
        precondition(AppSettings.adding(.fn, to: .pushToTalk, in: saved)["pushToTalk"] == [combo, .fn])
    }

    /// The hold-versus-double-tap machine. Real timings, so this costs about a second — worth it,
    /// because every branch here either drops a dictation or starts one nobody asked for, and
    /// none of it can be exercised without physically pressing a key.
    private static func checkGestures() {
        // Hold past the threshold: start on press, insert on release.
        run { monitor, log in
            precondition(monitor.simulate(.pushToTalk, down: true))
            pump(0.32)
            precondition(monitor.simulate(.pushToTalk, down: false))
            precondition(log() == ["start", "stop"], "\(log())")
        }

        // Short tap on its own: the session started, so it has to be thrown away — but only
        // after the double-tap window has passed with no second tap.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            precondition(log() == ["start"], "\(log())")
            pump(0.45)
            precondition(log() == ["start", "cancel"], "\(log())")
        }

        // Double tap locks hands-free, and cancels the discard the first tap queued up.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            pump(0.45)
            precondition(log() == ["start", "lock"], "\(log())")
            // A tap while locked finishes the session.
            _ = monitor.simulate(.pushToTalk, down: true)
            precondition(log() == ["start", "lock", "stop-locked"], "\(log())")
        }

        // "Dictate and send" is push to talk that asks for a Return afterwards.
        run { monitor, log in
            _ = monitor.simulate(.pressEnter, down: true)
            pump(0.32)
            _ = monitor.simulate(.pressEnter, down: false)
            precondition(log() == ["start+enter", "stop"], "\(log())")
        }

        // Releasing a different binding must not end someone else's hold.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pressEnter, down: false)
            pump(0.32)
            precondition(log() == ["start"], "\(log())")
            _ = monitor.simulate(.pushToTalk, down: false)
            precondition(log() == ["start", "stop"], "\(log())")
        }

        // Cancelling mid-hold discards it, and the trigger's own release is then a no-op
        // rather than a second stop that would insert the text anyway.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            precondition(monitor.simulate(.cancel, down: true))
            _ = monitor.simulate(.cancel, down: false)
            _ = monitor.simulate(.pushToTalk, down: false)
            pump(0.45)
            precondition(log() == ["start", "cancel"], "\(log())")
        }

        // Nothing to cancel: Esc has to reach the app the user is actually typing in.
        run { monitor, log in
            precondition(!monitor.simulate(.cancel, down: true))
            precondition(!monitor.simulate(.cancel, down: false))
            precondition(log().isEmpty)
        }

        // Hands-free binding: press to start, press again to finish.
        run { monitor, log in
            _ = monitor.simulate(.handsFree, down: true)
            precondition(log() == ["start", "lock"], "\(log())")
            _ = monitor.simulate(.handsFree, down: true)
            precondition(log() == ["start", "lock", "stop-locked"], "\(log())")
        }
    }

    /// A fresh monitor per scenario — no event tap, no shared state carried over.
    private static func run(_ body: (ShortcutMonitor, () -> [String]) -> Void) {
        let monitor = ShortcutMonitor()
        var log: [String] = []
        monitor.onStart = { log.append($0 ? "start+enter" : "start") }
        monitor.onStop = { log.append($0 ? "stop-locked" : "stop") }
        monitor.onCancel = { log.append("cancel") }
        monitor.onLock = { log.append("lock") }
        body(monitor, { log })
    }

    /// Let the run loop turn so the deferred discard actually fires.
    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
