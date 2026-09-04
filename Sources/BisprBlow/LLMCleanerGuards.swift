import Foundation

extension LLMCleaner {
    // True when cleanup clearly lost content: it elided part of the transcript, or came back far
    // shorter. An ellipsis anywhere counts — speech-to-text never emits one. Length is judged against
    // the transcript with fillers ALREADY removed: judging against the raw count builds in a bias as
    // large as the filler share, so "um um so uh uh i think we should just ship it um today and see
    // what breaks", correctly cleaned to nine words, was rejected because 55% of the raw 18 is 10.
    static func looksTruncated(_ cleaned: String, raw: String) -> Bool {
        let elides = { (text: String) in text.contains("...") || text.contains("…") }
        if elides(cleaned), !elides(raw) { return true }
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let cleanedWords = cleaned.split(whereSeparator: \.isWhitespace).count
        // Far longer than the transcript is not a cleanup: a leaked reasoning trace, or the model
        // answering the dictation instead of tidying it.
        if rawWords >= 5, cleanedWords > Int(Double(rawWords) * 2.5) { return true }
        let spokenWords = ruleClean(raw).split(whereSeparator: \.isWhitespace).count
        guard spokenWords >= 12 else {
            // Short dictations legitimately vary, so the floor is half rather than 0.55 — but not
            // unguarded: "Blue Jays, Blue Jays, Blue Jays" came back as "blue Jays.", six words to two.
            return spokenWords >= 3 && cleanedWords < Int((Double(spokenWords) * 0.5).rounded(.up))
        }
        return cleanedWords < Int(Double(spokenWords) * 0.55)
    }

    // Content-word recall: did the words carrying the meaning survive? Counting words is not enough —
    // a 45-word dictation came back at 24 with its whole second half deleted and PASSED, because 24
    // clears 55% of the filler-stripped 40. Which half the survivors came from is what matters.
    //
    // Complements the others: looksTruncated catches gross length collapse, rewordsContent catches a
    // swap on the coding path, and this catches deletion on both paths. Function words are excluded
    // via the recognizer's own list, so "we should probably" → "we should" is free.
    //
    // 0.8, and the margin is thinner than it looks: distinct words are counted, so the dictation above
    // lost 53% of its text but only 25% of its content vocabulary, scoring exactly 0.75. Measured
    // recall across bench/cases.json is 94-96%, so 0.8 keeps ~14 points of clearance.
    static let contentRecallFloor = 0.8
    static func losesContent(_ cleaned: String, raw: String) -> Bool {
        let content = { (text: String) -> Set<String> in
            Set(text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !AppContext.commonWords.contains($0) })
        }
        let spoken = content(raw)
        // Below this a single dropped word swings the ratio too far to judge anything.
        guard spoken.count >= 12 else { return false }
        let kept = spoken.intersection(content(cleaned)).count
        return Double(kept) < Double(spoken.count) * contentRecallFloor
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
    // deliberate: a rejection ships ruleClean, so the false-positive rate is what decides this guard.
    static func dropsTail(_ cleaned: String, raw: String) -> Bool {
        let words = { (text: String) in
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let spoken = words(raw).filter { $0.count >= 3 && !AppContext.commonWords.contains($0) }
        guard spoken.count >= 12, let last = spoken.last else { return false }
        // Position, not presence: searching all of `cleaned` lets an earlier occurrence satisfy it,
        // which is how a 157-word dictation silently lost its closing "...then that's for the cleanup
        // too" — "cleanup" also appeared 90 words earlier, at index 38 of 128. Requiring the match in
        // the last quarter is what makes "compressed the middle" distinguishable from "gave up".
        let out = words(cleaned)
        let tail = out.suffix(max(8, out.count / 4))
        // Prefix is for morphology, not a shorter unrelated word: "region" for "regions" is the same
        // word, "clean" for "cleanup" is not — the second half of that same miss, whose surviving tail
        // ended "should clean that up". One character of slack covers plural and possessive.
        return !tail.contains {
            $0.contains(last) || ($0.count >= 4 && last.hasPrefix($0) && last.count - $0.count <= 1)
        }
    }

    // Every guard in one place — they had already drifted: `--finish`, the seam bench.py scores
    // through, never ran `losesContent`, so that guard's false-positive rate had never been measured
    // on the set that exists to measure it.
    enum Rejection: String {
        case truncated = "dropped content"
        case lostContent = "lost content words"
        case droppedTail = "dropped the last thing said"
        case reworded = "reworded content on the coding path"
    }

    static func rejection(_ cleaned: String, raw: String, lowTouch: Bool,
                          allowed: Set<String>) -> Rejection? {
        // Small models summarize long dictations or stop mid-sentence. Losing the speaker's words is
        // worse than leaving fillers in.
        if looksTruncated(cleaned, raw: raw) { return .truncated }
        // Both paths: the meaning-carrying words have to still be there, even at an acceptable count.
        if losesContent(cleaned, raw: raw) { return .lostContent }
        // And the one that catches it stopping at the very end, where neither ratio can see it.
        if dropsTail(cleaned, raw: raw) { return .droppedTail }
        // Low touch promised delete/repunctuate/respell only. Check it: a swap leaves the length alone.
        if lowTouch, rewordsContent(cleaned, raw: raw, allowed: allowed) { return .reworded }
        return nil
    }

    // The low-touch invariant, checked instead of trusted: every output word is traceable to the
    // transcript in spoken order, or to the closed set the user gave us (dictionary + on-screen
    // words), which is where "work tree" → "worktree" comes from.
    //
    // Catches rewording — a swapped word, an invented connective, a reordering — and is deliberately
    // blind to deletion and capitalization, so it complements `looksTruncated` rather than replacing
    // it. Two exemptions, or it fires on ordinary output: a token starting with a digit ("200",
    // "500s") is a rendering of spoken number words, and two spoken words written as one ("back off"
    // → "backoff") is a deleted space.
    static func rewordsContent(_ cleaned: String, raw: String, allowed: Set<String> = []) -> Bool {
        let words = { (text: String) in
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let source = words(raw)
        var next = source.startIndex  // order matters: only ever scan forward
        for word in words(cleaned) {
            if word.first?.isNumber == true || allowed.contains(word) { continue }
            if let hit = source[next...].firstIndex(of: word) {
                next = source.index(after: hit)
                continue
            }
            // "back off" → "backoff": the pair has to sit at the scan head, or a compound could be
            // assembled from two words at opposite ends of the transcript.
            if let pair = source[next...].indices.first(where: {
                source.index(after: $0) < source.endIndex
                    && source[$0] + source[source.index(after: $0)] == word
            }) {
                next = source.index(pair, offsetBy: 2)
                continue
            }
            // A digit going back to the word it was heard as — the mirror of the exemption above.
            if let hit = source[next...].firstIndex(where: { Self.digitHomophones[$0]?.contains(word) == true }) {
                next = source.index(after: hit)
                continue
            }
            return true
        }
        return false
    }

    // What each digit may be turned back into, and nothing else. The recognizer decides between
    // "for", "fore" and "four" on sound alone and then formats the number: "Just keep the best 4 and
    // afterwards text." A closed table rather than "any word may replace a digit", which would licence
    // rewriting every number. Only 0-10: past ten the numeral is almost always what was meant.
    static let digitHomophones: [String: Set<String>] = [
        "0": ["zero", "oh", "owe"],
        "1": ["one", "won"],
        "2": ["two", "to", "too"],
        "3": ["three"],
        "4": ["four", "for", "fore"],
        "5": ["five"],
        "6": ["six"],
        "7": ["seven"],
        "8": ["eight", "ate"],
        "9": ["nine"],
        "10": ["ten"],
    ]

    // Everything the recognizer was biased toward — the dictionary plus the words on screen —
    // tokenized the way `rewordsContent` does, so respelling to a term the user gave us is allowed
    // and inventing one is not.
    static func allowedTerms(vocabulary: [String], draftTerms: [String]) -> Set<String> {
        Set((vocabulary + draftTerms).flatMap {
            $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        })
    }
}
