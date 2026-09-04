import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// `BisprBlow --self-check`: asserts the text logic that silently loses user words if it breaks.
// `precondition`, not `assert` — release builds strip asserts.
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
        // Filler-stuffed speech is measured against the transcript with the fillers already gone:
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
        // unapplied on every real dictation, so the substitution runs after the model.
        let vocab = ["Rohin", "Devi", "Claude", "worktree", "Kubernetes"]
        // One edit away respells; exact letters in the wrong case take the dictionary casing.
        precondition(LLMCleaner.applyVocabulary("Ask Devy about it.", vocabulary: vocab)
                     == "Ask Devi about it.")
        precondition(LLMCleaner.applyVocabulary("ask claude to fix it", vocabulary: vocab)
                     == "ask Claude to fix it")
        // A sound-alike is corrected only beside another dictionary hit — a misheard name arrives
        // as a misheard pair, and the pair is the evidence...
        precondition(LLMCleaner.applyVocabulary("My name is Robin Devy.", vocabulary: vocab)
                     == "My name is Rohin Devi.")
        // ...and the evidence must be a word the pass itself respelled. An exact hit is a word the
        // recognizer got RIGHT, and it fires on nearly every dictation: "per api key" shipped as
        // "Vite API git" when exact matches licensed their neighbours. The case fix still applies.
        precondition(LLMCleaner.applyVocabulary("a token bucket per api key",
                                                vocabulary: ["Vite", "API", "git"])
                     == "a token bucket per API key")
        // ...so the same sound-alikes alone are never touched: not every robin is Rohin and
        // not every cloud is Claude.
        precondition(LLMCleaner.applyVocabulary("a robin in the garden", vocabulary: vocab)
                     == "a robin in the garden")
        precondition(LLMCleaner.applyVocabulary("push it to cloud storage", vocabulary: vocab)
                     == "push it to cloud storage")
        // A word the recognizer got RIGHT is never respelled, however close it sits to a term:
        // levenshtein("code", "xcode") is 1, and "just put a code fix for it" shipped as "just put a
        // Xcode Vite for it". Being real English disqualifies it, not being long — "Devy" above is
        // four letters and must still respell.
        precondition(LLMCleaner.applyVocabulary("just put a code fix for it",
                                                vocabulary: ["Xcode", "Vite"])
                     == "just put a code fix for it")
        precondition(LLMCleaner.applyVocabulary("i sent you a gift",
                                                vocabulary: ["git"]) == "i sent you a gift")
        precondition(LLMCleaner.applyVocabulary("hold shift and click",
                                                vocabulary: ["Swift"]) == "hold shift and click")
        // The two-word join is an EXACT hit, so it must not license the phonetic tier next door. It
        // used to, and that one line corrupted 13 of 432 real dictations: "Says Blue Jay for all
        // six." went out as "git bluejay Vite all six."
        precondition(LLMCleaner.applyVocabulary("Says Blue Jay for all six.",
                                                vocabulary: ["bluejay", "git", "Vite"])
                     == "Says bluejay for all six.")
        precondition(LLMCleaner.applyVocabulary("not just say Blue Jay everywhere",
                                                vocabulary: ["bluejay", "git", "Prettier"])
                     == "not just say bluejay everywhere")
        // An inflection of a term is the term: "docs" must not be respelled to "doc", and must not
        // license its neighbours either ("run the docs page locally" → "run dev doc Vite locally").
        precondition(LLMCleaner.applyVocabulary("can you run the docs page locally",
                                                vocabulary: ["doc", "dev", "Vite"])
                     == "can you run the docs page locally")
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

        // Recognizer homophones, from the real transcript "...merged into Maine". Whole-word, and it
        // runs with an empty dictionary since it is not an entry — putting "main" in the dictionary
        // would drag the rhymes along at edit distance 1.
        precondition(LLMCleaner.applyVocabulary("merge it into Maine.", vocabulary: [])
                     == "merge it into main.")
        precondition(LLMCleaner.applyVocabulary("rebase onto Maine", vocabulary: vocab)
                     == "rebase onto main")
        precondition(LLMCleaner.applyVocabulary("check the mail in the rain", vocabulary: vocab)
                     == "check the mail in the rain")

        // The trailing period comes off when "End with a period" is off, but only a lone final full
        // stop: question marks carry meaning and a trailing identifier keeps its dots.
        precondition(LLMCleaner.droppingTrailingPeriod("Blue Jays.") == "Blue Jays")
        precondition(LLMCleaner.droppingTrailingPeriod("Did the deploy work?") == "Did the deploy work?")
        precondition(LLMCleaner.droppingTrailingPeriod("Ship it. Then tag it") == "Ship it. Then tag it")
        precondition(LLMCleaner.droppingTrailingPeriod("tail app.log") == "tail app.log")
        // Bare "like" mid-sentence is deliberately left in: "or like the task bar" is filler and
        // "and like the post" is a verb, and only what precedes the conjunction tells them apart.
        precondition(LLMCleaner.stripFillers("the system tray or like the task bar")
                     == "the system tray or like the task bar")

        // A leading-dot filename must survive the tidy pass, which used to glue the dot to the word
        // before it — read in the bench as the model "missing '.env'" when the model had it right.
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
        // Deliberate phrase repetition collapsing on a short dictation trips the truncation guard:
        // "Blue Jays, Blue Jays, Blue Jays" reached the cursor as "blue Jays." with every guard
        // silent, because under 12 words nothing was checked at all.
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
        // A filler that brought its own comma takes it along, or the comma lands against the previous
        // one ("Update the uh, this cookbook, Doc." → "Update the, this cookbook, Doc."). A dictation
        // at or under `LLMCleaner.verbatimWords` never reaches the model, so `ruleClean` is its only
        // pass and the stranded comma goes straight to the cursor.
        precondition(LLMCleaner.stripFillers("Update the uh, this cookbook, Doc.")
                     == "Update the this cookbook, Doc.")

        precondition(LLMCleaner.sanitize("```\nhello\n```", fallback: "x") == "hello")
        precondition(LLMCleaner.sanitize("", fallback: "fallback") == "fallback")

        // No em dash reaches the cursor, spaced or not. The few-shot demonstrates the comma, so
        // this is the backstop rather than the mechanism.
        precondition(LLMCleaner.sanitize("both — I don't know", fallback: "") == "both, I don't know")
        precondition(LLMCleaner.sanitize("both—I don't know", fallback: "") == "both, I don't know")
        precondition(!LLMCleaner.lowTouchFewShot.contains { $0.1.contains("—") })
        precondition(!LLMCleaner.fewShot.contains { $0.1.contains("—") })

        checkLowercaseSentences()
        // The recognizer marks a pause with an ellipsis. Verbatim from history: while it sat in the
        // transcript it also switched off looksTruncated's elision check on that dictation.
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
        // looksTruncated, because 24 clears 55% of the filler-stripped 40 by two words.
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
        // Verbatim from history, and it shipped: a 149-word dictation lost its whole closing sentence
        // and every guard stayed silent. Real strings rather than a paraphrase, because a shortened
        // stand-in trips `losesContent` and stops demonstrating the hole. Two holes, both pinned here.
        // One: presence, not position — "cleanup" is the last content word and also appears 90 words
        // earlier, so scanning the whole output found it at index 38 of 128. Two: the prefix loosener
        // — "clean" is a five-character prefix of "cleanup", so "...should clean that up" passed.
        let ramble = "Also, yeah, the dedication needs to be really worked on. I don't know why words keep getting "
            + "cut off. I think it's the LLM being too aggressive. Like, it should be aggressive when doing "
            + "a bunch of intense cleanup. Like, uh, like, the goal is we're trying to transcribe to real "
            + "text and identify intent. But if we say some, like, chopped phrase, just to fill in a larger "
            + "phrase, such as, um, like 2nd is, which makes no sense out of context, but the user actually "
            + "wants to say 2nd is to fill in a phrase. Like, that should be fine. But if we say, but if "
            + "the LLM can understand the intent, like, oh, there's a lot of, like, there's a contradiction "
            + "in the paragraph, then the LLM should clean that up. There's stutters or, like, filler words "
            + "that aren't needed, then that's for the cleanup too."
        let rambleCut = "also, the dedication needs to be really worked on. I don't know why words keep getting cut "
            + "off. I think it's the LLM being too aggressive. it should be aggressive when doing a bunch "
            + "of intense cleanup. the goal is we're trying to transcribe to real text and identify intent. "
            + "but if we say some chopped phrase, just to fill in a larger phrase, such as, like 2nd is, "
            + "which makes no sense out of context, but the user actually wants to say 2nd is to fill in a "
            + "phrase. that should be fine. but if we say, but if the LLM can understand the intent, "
            + "there's a lot of there's a contradiction in the paragraph, then the LLM should clean that up"
        precondition(!LLMCleaner.looksTruncated(rambleCut, raw: ramble), "82% of the words")
        precondition(!LLMCleaner.losesContent(rambleCut, raw: ramble), "the tail repeats the body")
        precondition(LLMCleaner.dropsTail(rambleCut, raw: ramble), "the closing sentence is gone")
        // The morphology the prefix loosener exists for still passes: one character of slack.
        precondition(!LLMCleaner.dropsTail(
            "Check the snap region before you rebase, then run the whole suite again against the "
            + "staging database and the local snap region.",
            raw: "check the snap regions before you rebase, and then run the whole suite again "
            + "against the staging database and the local snap regions"))

        // Both dictation cues have to resolve: a misspelled or removed system sound makes
        // `NSSound(named:)` nil and `playSound` a silent no-op with nothing in the log. `Tink` is
        // asserted absent because it is the tick macOS plays for a rejected keystroke.
        precondition(NSSound(named: "Purr") != nil, "the start cue is missing")
        precondition(NSSound(named: "Pop") != nil, "the end cue is missing")

        // A dictation short enough to skip the model (`LLMCleaner.verbatimWords`) ships `ruleClean`,
        // so `ruleClean` is what has to keep the user's words. "Second is." was reported twice: the
        // model returned "Second." and no guard could see a two-letter word go.
        precondition(LLMCleaner.verbatimWords >= 8, "8 is where this user's history turns over")
        precondition(LLMCleaner.ruleClean("Second is.") == "Second is.")
        precondition(LLMCleaner.ruleClean("Hello?") == "Hello?", "a question stays a question")
        precondition(LLMCleaner.ruleClean("Well, right.") == "Well, right.")
        // It is still a cleanup, not a pass-through: fillers and doubled words go.
        precondition(LLMCleaner.ruleClean("Update the uh, this cookbook, Doc.")
                        .contains("this cookbook"), "the content survives")
        precondition(!LLMCleaner.ruleClean("um does it uh does it work").contains("uh"))

        checkLowTouchInvariant()

        // Verbatim from history: the recognizer chose "four" over "for" by sound and formatted it as
        // a numeral, and the guard then threw away the only stage that could fix it.
        precondition(!LLMCleaner.rewordsContent("Just keep the best for and afterwards text.",
                                                raw: "Just keep the best 4 and afterwards text."))
        precondition(!LLMCleaner.rewordsContent("push to dev, not prod", raw: "push 2 dev not prod"))
        // The exemption is a closed table, not a licence to rewrite numbers.
        precondition(LLMCleaner.rewordsContent("keep the best bits", raw: "keep the best 4"))
        precondition(LLMCleaner.rewordsContent("retry many times", raw: "retry 3 times"))
        // A real number the model spelled out stays legal in the other direction too.
        precondition(!LLMCleaner.rewordsContent("retry three times", raw: "retry 3 times"))

        // The floor has to clear the cleanup latency observed in the log — 280-729ms, only weakly
        // tied to length. A 400ms base sat inside that spread, so the deadline coin-flipped and threw
        // away the model's punctuation on ~30% of dictations to save 14-47ms.
        precondition(LLMCleaner.deadlineMs(words: 0) > 729)
        precondition(LLMCleaner.deadlineMs(words: 47) > 729)
        // ...and a long dictation still gets proportionally more, since cost does grow with length:
        // measured on qwen3-0.6b, 0.20s for twelve words against 1.51s for two hundred and forty.
        precondition(LLMCleaner.deadlineMs(words: 240) > 1510)
        precondition(LLMCleaner.deadlineMs(words: 100_000) == 2500)
        // Accurate resolves to a model several times the size, so it gets several times the budget at
        // every length: on the fast budget it is not more accurate, it just ships the same rule-cleaned
        // text later.
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

        // Recognizer bias comes from the words on screen, and a plain lowercase word in a code buffer
        // is the one a general model gets wrong ("query" heard as "quarry"). So plain domain words
        // survive, identifiers lead, and common English must not crowd them out of a capped list.
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
        checkHistoryRoundTrip()
        checkShortcuts()
        checkGestures()

        // The /no_think switch goes on its own LINE. Glued to "Transcript: <words>" it reads as part
        // of the transcript, and the low-touch rules promise every spoken word survives — so the
        // coding path copied it out, sometimes mangled past `sanitize` ("/no_thing", "/no_ideas") and
        // sometimes copying the nearest few-shot demo instead. 10 of 15 short terminal dictations
        // wrong glued, 0 of 15 on its own line.
        let switched = LLMCleaner.withThinkingOff(
            [["role": "user", "content": "App: Terminal (coding)\nTranscript: revert the last commit"]],
            model: "Qwen3-0.6B-MLX-4bit")
        let content = switched[0]["content"]!
        precondition(content.hasSuffix("\n/no_think"), "the switch must sit on its own line")
        precondition(content.contains("Transcript: revert the last commit\n"),
                     "the transcript line must survive the switch untouched")
        // Not a Qwen3 model, no switch: it would be a literal instruction to anything else.
        precondition(LLMCleaner.withThinkingOff(
            [["role": "user", "content": "hi"]], model: "llama-3.2-3b")[0]["content"] == "hi")
        checkCloudSync()
        checkAccurateResolution()

        print("self-check passed")
    }
}
