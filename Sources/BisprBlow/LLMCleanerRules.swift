import Foundation

extension LLMCleaner {
    // MARK: - Deterministic filler removal

    // Removes the fillers a regex gets right every time. Runs on the model's output too: measured on
    // qwen3-0.6b, the model leaves "uh" and discourse "like" in about as often as it strips them.
    //
    // Two tiers, because the cost of a mistake is asymmetric. "um" and friends are never words, and
    // neither are "oh", "hm", "hmm". "like" and "you know" are, so those are only touched in the
    // shapes a real use never takes.
    private static let hardFillers = ["um", "umm", "ummm", "uh", "uhh", "uhhh",
                                      "er", "erm", "ah", "oh", "hm", "hmm"]
    // Words a comma after a filler follows. In history.json, a comma there almost always punctuated
    // only the filler ("for, um, red"); "sign in, uh, then" loses a real one, and keeps its words.
    private static let midClauseWords = ["the", "a", "an", "for", "on", "of", "to", "in", "at", "with",
                                         "from", "and", "but", "or", "because", "if", "our", "your",
                                         "my", "their", "his", "her", "its", "is", "are", "was", "be",
                                         "very"]

    static func stripFillers(_ text: String) -> String {
        var text = text
        let hard = hardFillers.joined(separator: "|")
        // A filler standing as its own sentence takes its full stop with it, or "Oh. Uh. the login
        // flow" comes out "Oh.. the login flow". Looped: one call rewrites each match once and a
        // consumed separator stops the next match starting, and these arrive in runs.
        let standalone = "(?i)(^|[.!?]\\s+|\u{1})(?:\(hard))\\s*[.!?]+\\s*"
        while true {
            let next = text.replacingOccurrences(of: standalone, with: "$1\u{1}",
                                                 options: .regularExpression)
            if next == text { break }
            text = next
        }
        // Opening a sentence, comma or no comma. The next word takes the capital the filler held.
        text = text.replacingOccurrences(
            of: "(?i)(^|[.!?]\\s+|\u{1})(?:\(hard)),?\\s+", with: "$1\u{1}",
            options: .regularExpression)
        // A filler carries off the comma punctuating it, or removing the word strands it against the
        // previous one ("Update the uh, this cookbook, Doc." → "Update the, this cookbook, Doc.") —
        // and a dictation at or under `verbatimWords` gets no model pass to tidy it. One pass, not
        // two: the leading `[\s\u{1}]` also matches the space inside ", um,", so a comma-bracketed
        // filler collapses to a single comma. That comma is right after "Basically" and wrong after
        // "is" ("is, um, standard"), so after a word in `midClauseWords` both commas go first.
        text = text.replacingOccurrences(
            of: "(?i)\\b(\(midClauseWords.joined(separator: "|")))\\s*,\\s*(?:\(hard))\\s*,\\s*",
            with: "$1 ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?i)(^|[\\s\u{1}])(?:\(hard))\\s*,\\s*", with: "$1", options: .regularExpression)
        // Anywhere else. `(^|[\s,\u{1}])` keeps "umbrella" and "uh-huh" intact, and counts a marker
        // left above as a word boundary so "um uh the tests" loses both fillers.
        for filler in hardFillers {
            text = text.replacingOccurrences(
                of: "(?i)(^|[\\s,\u{1}])\(filler)([\\s,.!?]|$)",
                with: "$1$2",
                options: .regularExpression
            )
        }
        for hedge in ["like", "you know"] {
            // Bracketed by commas: "it was, like, really slow". A real "like" is never bracketed.
            // Replaced by a space — the commas were only there for the hedge.
            text = text.replacingOccurrences(
                of: "(?i),\\s*\(hedge)\\s*,\\s*", with: " ", options: .regularExpression)
            // Trailing: "it's too slow, you know."
            text = text.replacingOccurrences(
                of: "(?i),\\s*\(hedge)\\s*([.!?]|$)", with: "$1", options: .regularExpression)
        }
        // Opening a sentence: "Too high. Like, way too high." \u{1} marks where the capital goes;
        // a transcript never contains one.
        text = text.replacingOccurrences(
            of: "(?i)(^|[.!?]\\s+)(?:like|you know),\\s*", with: "$1\u{1}", options: .regularExpression)
        while let mark = text.range(of: "\u{1}") {
            let rest = text[mark.upperBound...]
            text = String(text[..<mark.lowerBound]) + rest.prefix(1).uppercased() + String(rest.dropFirst())
        }
        // Bare "like" mid-sentence ("it could be like closer to") is left to the prompt: telling
        // filler from comparison needs both sides, and a wrong guess eats "sounds like really bad news".
        return tidy(text)
    }

    // Collapse leftover whitespace and dangling commas. The lookahead is load-bearing: punctuation is
    // only pulled back onto the previous word when it ENDS something, or every leading-dot filename
    // gets glued to the word before ("check the .env file" → "check the.env file").
    private static func tidy(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        // A filler removed from between commas leaves both behind, and the pull-back below welds them
        // into ",,". Collapse here so any producer is covered.
        text = text.replacingOccurrences(of: ",(\\s*,)+", with: ",", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?])(?=\\s|$)", with: "$1",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spoken lists

    // One family per list, so "first ... two ..." is not a sequence. Digits are there because the
    // model writes "1." itself often enough.
    private static let ordinals: [(words: [String], marker: NSRegularExpression)] = [
        ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"],
        ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"],
        (1...10).map(String.init),
    ].map { words in
        (words, try! NSRegularExpression(
            pattern: "(?i)\\b(\(words.joined(separator: "|")))(?:\\s*[,:.](?=\\s)|\\s+is\\b)\\s*"))
    }

    // "One, X, two, Y, and three, Z" becomes a numbered list, one item per line. Why each condition
    // exists, with the real dictation behind it, is in CLAUDE.md and `checkNumberedList`. The last item
    // ends with its sentence, because nothing spoken marks where a list stops.
    static func numberedList(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let ns = text as NSString
        for (family, regex) in ordinals {
            let markers = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            func value(_ marker: NSTextCheckingResult) -> Int? {
                family.firstIndex(of: ns.substring(with: marker.range(at: 1)).lowercased())
            }
            func opensClause(_ marker: NSTextCheckingResult) -> Bool {
                ns.substring(to: marker.range.location)
                    .range(of: "(?i)(?:^|[.!?:,]\\s|\\band\\s)$", options: .regularExpression) != nil
            }
            // Mid-clause, only a comma or colon marks a list: "this one is broken. Two, ..." is prose.
            func canStart(_ marker: NSTextCheckingResult) -> Bool {
                value(marker) == 0 && (opensClause(marker)
                    || ns.substring(with: NSRange(location: NSMaxRange(marker.range(at: 1)),
                                                  length: NSMaxRange(marker.range) - NSMaxRange(marker.range(at: 1))))
                        .contains(where: { $0 == "," || $0 == ":" }))
            }
            for (start, first) in markers.enumerated() where canStart(first) {
                var chain = [first]
                for next in markers[(start + 1)...] {
                    // "the first one is the Canary ... so one, how do I test it? Two, ..." counts
                    // from the "one" nearest the "two".
                    if chain.count == 1, canStart(next) { chain = [next]; continue }
                    guard opensClause(next) else { continue }
                    guard value(next) == chain.count else { break }
                    chain.append(next)
                }
                guard chain.count >= 2 else { continue }

                var items: [String] = []
                for (i, marker) in chain.enumerated() {
                    let from = marker.range.upperBound
                    let to = i + 1 < chain.count ? chain[i + 1].range.location : ns.length
                    items.append(ns.substring(with: NSRange(location: from, length: to - from)))
                }
                // The last item stops at its first sentence end; the rest is prose again.
                var tail = ""
                if let end = items[items.count - 1].range(of: "[.!?](?=\\s|$)", options: .regularExpression) {
                    tail = String(items[items.count - 1][end.upperBound...])
                    items[items.count - 1] = String(items[items.count - 1][..<end.upperBound])
                }
                // A comma or "and" was only joining the items.
                items = items.map {
                    $0.replacingOccurrences(of: "(?i)(?:[\\s,]+|\\band\\b)+$", with: "", options: .regularExpression)
                }
                guard items.allSatisfy({ $0.contains(where: \.isLetter) }) else { continue }
                // "One is X, two is Y, and three is Z." should not end only its last item with a stop.
                if items.dropLast().allSatisfy({ $0.last.map { !".!?".contains($0) } ?? true }), items[items.count - 1].hasSuffix(".") {
                    items[items.count - 1].removeLast()
                }

                var intro = ns.substring(to: chain[0].range.location).trimmingCharacters(in: .whitespaces)
                if intro.hasSuffix(",") { intro.removeLast() }
                if let last = intro.last, !".!?:".contains(last) { intro += ":" }
                let list = items.enumerated()
                    .map { "\($0.offset + 1). \($0.element.prefix(1).uppercased())\($0.element.dropFirst())" }
                    .joined(separator: "\n")
                let rest = tail.trimmingCharacters(in: .whitespaces)
                return (intro.isEmpty ? "" : intro + "\n") + list
                    + (rest.isEmpty ? "" : "\n\n" + numberedList(rest))
            }
        }
        return text
    }

    // MARK: - Rule-based fallback

    static func ruleClean(_ raw: String) -> String {
        // Immediately repeated words ("the the" → "the"). Before the fillers: the filler pass consumes
        // the space it matched on, so "uh uh" keeps its second "uh" unless the pair collapsed first.
        var text = raw.replacingOccurrences(
            of: "(?i)\\b(\\w+)(\\s+\\1)+\\b",
            with: "$1",
            options: .regularExpression
        )
        text = stripFillers(text)
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }
}
