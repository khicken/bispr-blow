import Foundation

extension LLMCleaner {
    // Homophones the recognizer picks the wrong side of, keyed lowercase. The swap is
    // unconditional, so "the coast of Maine" becomes "main" too. Keep it short.
    static let misheard: [String: String] = ["maine": "main"]

    // The gate `near` answers to: macOS's own word list, filtered to the lengths `near` can fire on.
    // Empty when the file is missing, which restores the old false positives rather than disabling
    // respelling. `warmUp` builds it so the first dictation does not spend its deadline here.
    static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
        else {
            logLine("vocabulary guard: /usr/share/dict/words missing, respelling unguarded")
            return []
        }
        return Set(text.split(separator: "\n").lazy
            .filter { $0.count >= 4 }
            .map { $0.lowercased() })
    }()

    // Deterministic dictionary respelling, after the model, because at 0.6B-1.7B the model does not
    // do it ("Christian Parik" shipped uncorrected with both names in the prompt) and the rules path
    // has no model at all. Tiered, because a wrong swap corrupts the user's words:
    //
    // - exact: same letters, wrong case → take the dictionary casing ("claude" → "Claude").
    // - near: edit distance ≤1 (≤2 from eight letters), four letters minimum — "Parik" → "Parikh"
    //   but never "def" → "dev".
    // - loose: sound-alike by phonetic key, accepted ONLY next to a word this pass just respelled;
    //   alone it turns every "cloud" into "Claude". An exact match is NOT evidence — counting them
    //   shipped "per api key" as "Vite API git".
    // - joined: two words that concatenate into a term ("work tree" → "worktree").
    //
    // Ahead of all four is `misheard`, for words the dictionary cannot express safely: "main" as an
    // entry would make `near` rewrite "mail", "rain", "pain" and "gain" too.
    static func applyVocabulary(_ text: String, vocabulary: [String]) -> String {
        let terms = vocabulary.filter { !$0.isEmpty && !$0.contains(" ") }

        // Words and the separators between them, so reassembly preserves the original spacing.
        var words: [String] = []
        var seps: [String] = [""]
        for ch in text {
            if ch.isWhitespace {
                if words.count == seps.count { seps.append(String(ch)) } else { seps[seps.count - 1].append(ch) }
            } else {
                if words.count < seps.count { words.append(String(ch)) } else { words[words.count - 1].append(ch) }
            }
        }
        if words.count == seps.count { seps.append("") }

        func bare(_ w: String) -> String {
            w.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]}”’([{“‘.,!?;:"))
        }
        // Identifiers, paths, numbers: not the recognizer mishearing a name, leave them alone.
        func plainWord(_ b: String) -> Bool {
            !b.isEmpty && b.allSatisfy(\.isLetter) && !b.dropFirst().contains(where: \.isUppercase)
        }
        func replace(_ i: Int, with term: String) {
            let w = words[i], b = bare(w)
            guard let r = w.range(of: b) else { return }
            words[i] = w.replacingCharacters(in: r, with: term)
        }

        enum Tier: Int { case none, loose, near, exact }
        func tier(_ b: String, _ term: String) -> Tier {
            let w = b.lowercased(), t = term.lowercased()
            if w == t { return .exact }
            guard w.count >= 3, t.count >= 3 else { return .none }
        // An inflection of a term IS the term, heard correctly. "docs" is one edit from "doc" and is
        // not in the word list, so `near` respelled it — destroying the plural and marking the word
        // corrected, which licensed `loose` on both sides ("run the docs page locally" → "run dev doc
        // Vite locally"). Both directions, since the dictionary may hold either form.
            if w == t + "s" || w == t + "es" || t == w + "s" || t == w + "es" { return .none }
        // `near` fires without the matched-neighbour evidence `loose` demands, so it must never
        // overwrite a word the recognizer got right: levenshtein("code", "xcode") == 1 shipped "just
        // put a Xcode Vite for it". Across the shipped dictionary "git" ate gift/gist/grit, "Vite" ate
        // site/cite/bite, "Swift" ate shift, "linter" ate liner/linger/linker, "Claude" ate clause.
        // Being real English is the discriminator, not being long: "Parik" → "Parikh" is five letters
        // and is exactly what the dictionary is for.
            if w.count >= 4, !englishWords.contains(w),
               levenshtein(w, t) <= (max(w.count, t.count) >= 8 ? 2 : 1) { return .near }
            if abs(w.count - t.count) <= 3, levenshtein(phoneticKey(w), phoneticKey(t)) <= 1 { return .loose }
            return .none
        }

        var corrected = Set<Int>()
        var looseCandidates: [(index: Int, term: String)] = []
        var i = 0
        while i < words.count {
            let b = bare(words[i])
            guard plainWord(b) else { i += 1; continue }
            if let fix = Self.misheard[b.lowercased()] {
                replace(i, with: fix)
                corrected.insert(i)
                i += 1
                continue
            }
            // Two words that join into one term: "work tree" → "worktree".
            if i + 1 < words.count, words[i].hasSuffix(bare(words[i])) {
                let b2 = bare(words[i + 1])
                if plainWord(b2), let term = terms.first(where: { tier(b + b2, $0) == .exact }) {
                    let tail = String(words[i + 1].dropFirst(b2.count))
                    replace(i, with: term)
                    words[i] += tail
                    words.remove(at: i + 1)
                    seps.remove(at: i + 1)
                    // Deliberately NOT `corrected.insert(i)`: this branch fires on an `.exact` match,
                    // so the recognizer heard it right and only the spacing was ours to fix. An exact
                    // hit must not license the phonetic tier on its neighbours. Measured over 432 real
                    // dictations, this one line accounted for 13 of the 16 corruptions — "Says Blue Jay
                    // for all six." left as "git bluejay Vite all six."
                    i += 1
                    continue
                }
            }
            var best: (Tier, String)? = nil
            for term in terms {
                let t = tier(b, term)
                if t.rawValue > (best?.0.rawValue ?? 0) { best = (t, term) }
            }
            switch best {
            case let (.exact, term)? where term.contains(where: \.isUppercase) && b != term:
                replace(i, with: term)
            case (.exact, _)?:
                break
            case let (.near, term)?:
                replace(i, with: term)
                corrected.insert(i)
            case let (.loose, term)?:
                looseCandidates.append((i, term))
            default:
                break
            }
            i += 1
        }
        for (index, term) in looseCandidates where corrected.contains(index - 1) || corrected.contains(index + 1) {
            replace(index, with: term)
        }

        return zip(seps, words + [""]).map { $0 + $1 }.joined()
    }

    // Soundex-style consonant classes, first letter included (so C and K agree), vowels reset the
    // run. "christian" and "krishin" land one edit apart; "clot", "cloud" and "claude" collapse to
    // the same key — which is why `loose` needs a matched neighbour.
    private static func phoneticKey(_ s: String) -> String {
        var out = ""
        var last: Character? = nil
        for ch in s {
            var code: Character? = nil
            switch ch {
            case "b", "f", "p", "v": code = "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": code = "2"
            case "d", "t": code = "3"
            case "l": code = "4"
            case "m", "n": code = "5"
            case "r": code = "6"
            case "h", "w": continue
            default: last = nil; continue
            }
            if code != last { out.append(code!) }
            last = code
        }
        return out
    }

    // Whether a word the user retyped by hand is worth keeping in the dictionary. Same discriminator
    // as the respeller: being real English. An entry for a real word licenses `.near` on its
    // neighbours, which is how "code" turned "just put a code fix for it" into "just put a Xcode Vite
    // for it". BOTH words are tested against the word list — an edit away from real English is as
    // likely to be a change of mind as a mishear — so the app learns only from what the recognizer
    // plainly invented ("Parik", "kubernetis"). The pair also has to be a plausible mishear: same
    // rough length, and either one edit apart or sharing a phonetic key.
    static func learnable(misheard: String, corrected: String) -> Bool {
        let heard = misheard.lowercased(), fixed = corrected.lowercased()
        guard heard != fixed,
              corrected.count >= 3, corrected.count <= 30,
              corrected.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
              misheard.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
              !englishWords.contains(fixed),
              // Four letters is where `englishWords` starts, so a shorter heard word is one the list
              // has no opinion about — and an opinion is the whole basis for learning here.
              heard.count >= 4, !englishWords.contains(heard),
              abs(heard.count - fixed.count) <= 3
        else { return false }
        return levenshtein(heard, fixed) <= 2
            || levenshtein(phoneticKey(heard), phoneticKey(fixed)) <= 1
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var row = Array(0...y.count)
        for (i, cx) in x.enumerated() {
            var prev = row[0]
            row[0] = i + 1
            for (j, cy) in y.enumerated() {
                let cost = cx == cy ? prev : min(prev, row[j], row[j + 1]) + 1
                prev = row[j + 1]
                row[j + 1] = cost
            }
        }
        return row[y.count]
    }
}
