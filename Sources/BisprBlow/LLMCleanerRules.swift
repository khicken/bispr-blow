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
        // filler collapses to a single comma. A separate bracketed rule undoes that; there isn't one.
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
