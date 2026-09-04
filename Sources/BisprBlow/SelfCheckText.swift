import Foundation

extension SelfCheck {
    // Lowercase sentence starts, and the three kinds of word that must survive it: the failure that
    // matters is a capital eaten off a term the user put in the dictionary to get it spelled that way.
    static func checkLowercaseSentences() {
        let vocab = ["Kubernetes", "Bluejay", "Priya"]
        func lower(_ s: String) -> String { LLMCleaner.lowercaseSentenceStarts(s, keeping: vocab) }

        precondition(lower("Run the tests. Then commit.") == "run the tests. then commit.")
        // "I" keeps its capital wherever it lands. This case used to assert the opposite, which is
        // how "i thought I did that" reached a real dictation looking like a typo.
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
        precondition(lower("we told Alice and Bob") == "we told Alice and Bob")
        precondition(lower("Ask Sam about it") == "ask Sam about it")
        // A full stop inside quotes still ends the sentence; a comma does not start one.
        precondition(lower("He said \"go.\" Then he left.") == "he said \"go.\" then he left.")
        precondition(lower("First, Then second") == "first, Then second")
        // Newlines open a sentence, and the text is otherwise returned byte for byte.
        precondition(lower("One thing\nTwo things") == "one thing\ntwo things")
        precondition(lower("") == "")
        precondition(lower("   Spaced   out  ") == "   spaced   out  ")
    }

    // The coding path promises the model may only delete, repunctuate and respell; `rewordsContent`
    // makes that a fact. Every case here is one the few-shot demonstrates or the bench caught.
    static func checkLowTouchInvariant() {
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
        // A compound may only be assembled from a pair at the scan head, never from two words at
        // opposite ends of the transcript.
        precondition(reworded("Backoff.", "back it off", []))

        // And the reason this is gated on the coding path: a good polish-path rewrite fails it.
        precondition(reworded(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the session.",
            "okay so um i tested the new build and uh the login flow it's mostly working but i found "
            + "like two issues one is the spinner never goes away and two um when you log out it "
            + "doesn't clear the session", []))
    }

    // Learning from a hand-typed fix, a new way to write to the dictionary — and the dictionary is
    // the one thing that can turn a correct transcript into a wrong one. Both halves are checked:
    // what counts as a correction, and what is worth keeping.
    static func checkCorrections() {
        func fix(_ before: String, _ after: String) -> CorrectionWatcher.Correction? {
            CorrectionWatcher.substitution(from: before, to: after)
        }

        // One word swapped in place is the whole signal.
        let one = fix("ask Devy about the deploy", "ask Devi about the deploy")
        precondition(one?.misheard == "Devy" && one?.corrected == "Devi")

        // Punctuation belongs to the sentence, not to the word that goes in the dictionary.
        let punctuated = fix("thanks, Devy.", "thanks, Devi.")
        precondition(punctuated?.corrected == "Devi", "\(punctuated?.corrected ?? "nil")")

        // Everything else is the user writing, and there is no telling which half of a rewrite was a
        // mishear. A second changed word, a word added, a word deleted: all nil.
        precondition(fix("ask Devy about the deploy", "ask Devi about the release") == nil)
        precondition(fix("ask Devy about it", "ask Devy about it today") == nil)
        precondition(fix("ask Devy about it", "ask about it") == nil)
        precondition(fix("same text", "same text") == nil)

        // Worth keeping: a name the word list has never heard of, one edit away from what we wrote.
        precondition(LLMCleaner.learnable(misheard: "Devy", corrected: "Devi"))
        precondition(LLMCleaner.learnable(misheard: "Bispr", corrected: "BisprBlow") == false)
        precondition(LLMCleaner.learnable(misheard: "kubernetis", corrected: "Kubernetes"))

        // Not worth keeping: in all three the recognizer produced real English, so it got the word
        // right as far as the word list can tell. "code" → "Xcode" is the pair that turned "just put
        // a code fix for it" into "just put a Xcode Vite for it", and it is indistinguishable from
        // "prod" → "proud".
        precondition(LLMCleaner.learnable(misheard: "prod", corrected: "proud") == false)
        precondition(LLMCleaner.learnable(misheard: "code", corrected: "Xcode") == false)
        precondition(LLMCleaner.learnable(misheard: "shift", corrected: "Swift") == false)

        // Not a mishear at all: someone rewrote the word.
        precondition(LLMCleaner.learnable(misheard: "send", corrected: "cancel") == false)
        precondition(LLMCleaner.learnable(misheard: "Devi", corrected: "Devi") == false)

        // A word with a digit or an underscore is a variable name, not a dictated word.
        precondition(LLMCleaner.learnable(misheard: "userId", corrected: "user_id") == false)
    }

    // The field's own name is context too, and it leads: in an empty message box it is all there is.
    static func checkFieldLabel() {
        let terms = AppContext(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            windowTitle: "Slack", draft: "shipping this today",
            fieldLabel: "Message #platform-team"
        ).draftTerms
        precondition(terms.contains("#platform-team"), "\(terms)")
        precondition(terms.contains("shipping"), "\(terms)")
    }

    // History is written and read by two separate JSON codecs, and they once disagreed about dates —
    // so every launch decoded nothing, `try?` swallowed it, and history silently started over. An
    // empty history is indistinguishable from a new install, so only a round trip catches this.
    static func checkHistoryRoundTrip() {
        let entry = DictationEntry(
            id: UUID(), date: Date(timeIntervalSince1970: 1_788_000_000),
            raw: "um so ship it", cleaned: "Ship it.", appName: "Claude",
            bundleID: "com.anthropic.claudefordesktop", provider: "on-device",
            durationSeconds: 1.5)
        let data = try! HistoryStore.encoder.encode([entry])
        let back = try! HistoryStore.decoder.decode([DictationEntry].self, from: data)
        precondition(back.count == 1)
        precondition(back[0].id == entry.id)
        precondition(back[0].cleaned == entry.cleaned)
        precondition(Int(back[0].date.timeIntervalSince1970) == 1_788_000_000,
                     "history date did not survive the round trip: \(back[0].date)")
    }
}
