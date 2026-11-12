import FluidAudio
import Foundation

// NVIDIA Parakeet TDT ("ultra") through FluidAudio, on the Neural Engine, plus FluidAudio's CTC
// keyword rescorer for the dictionary. Why this and not Apple, and the settings that were measured:
// CLAUDE.md, Speech recognition rules. Numbers: bench/asr/results/summary.md.
actor Parakeet {
    static let shared = Parakeet()

    private var asr: AsrManager?
    private var ctc: CtcModels?
    private var decoderLayers = 2
    private var boost: VocabularyBoostingSession?
    private var boostTerms: [String] = []
    private var boostAliases: [String: [String]] = [:]

    var isReady: Bool { asr != nil }

    // Loads the models from the app bundle when an installer put them there, else fetches them once
    // (about 700MB into Application Support/FluidAudio). Until this finishes, or if it fails,
    // `Transcriber` stays on Apple's recognizer.
    func load() async {
        guard asr == nil else { return }
        do {
            let start = Date()
            Self.linkBundledModels()
            let dir = try await AsrModels.download(version: .ultra)
            let models = try await AsrModels.load(from: dir, version: .ultra)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            decoderLayers = await manager.decoderLayerCount
            ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            asr = manager
            // The first call through a freshly loaded CoreML model pays for its own setup; a second
            // of silence keeps that off the first real dictation.
            _ = await transcribe(Array(repeating: 0, count: 16_000), vocabulary: [], heardAs: [:])
            logLine("parakeet ready in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        } catch {
            logLine("parakeet unavailable, staying on Apple: \(error)")
        }
    }

    // `samples` is 16kHz mono. Nil is a failure; the words are lost, so the caller has to say so.
    func transcribe(_ samples: [Float], vocabulary: [String], heardAs: [String: [String]]) async -> String? {
        guard let asr else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await asr.transcribe(samples, decoderState: &state)
            let aliases = Self.aliases(heardAs)
            guard let session = await boostSession(for: vocabulary, aliases: aliases) else { return result.text }
            let rescored = await session.rescore(
                text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
            let kept = (rescored?.replacements ?? []).compactMap { r -> (String, String)? in
                guard let term = r.replacementWord, Self.isMishear(r.originalWord, of: term, aliases: aliases) else { return nil }
                return (r.originalWord, term)
            }
            guard let text = Self.applying(kept, to: result.text) else {
                logLine("parakeet: \(kept.count) vocabulary fixes did not line up with the transcript; skipped")
                return result.text
            }
            return text
        } catch {
            logLine("parakeet transcribe failed: \(error)")
            return nil
        }
    }

    // An installer ships the weights in Contents/Resources/models. They are linked into FluidAudio's
    // cache folder rather than loaded by path, because the vocab rescorer reads its tokenizer from
    // that cache folder whatever folder the models came from — loaded by path alone, the dictionary
    // silently stops applying. A real folder already there wins; a link left dangling by a moved
    // or deleted app is replaced.
    static func linkBundledModels() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("models") else { return }
        let fm = FileManager.default
        for cache in [AsrModels.defaultCacheDirectory(for: .ultra), CtcModels.defaultCacheDirectory(for: .ctc110m)] {
            // Dangling whether or not this bundle has weights: left in place, the download below
            // cannot write through it and Parakeet never loads.
            if (try? fm.destinationOfSymbolicLink(atPath: cache.path)) != nil, !fm.fileExists(atPath: cache.path) {
                try? fm.removeItem(at: cache)
            }
            let source = bundled.appendingPathComponent(cache.lastPathComponent)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: cache.path) else { continue }
            try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.createSymbolicLink(at: cache, withDestinationURL: source)
            } catch {
                logLine("parakeet: could not link bundled \(cache.lastPathComponent): \(error)")
            }
        }
    }

    // Mishears of a term that real words own, so only acoustics can tell them apart: Ultra writes
    // "clod" for Claude, and nothing downstream respells a real word.
    private static let mishears = ["claude": ["quad", "claw", "clawed", "clod"]]

    // Built-in mishears plus the user's, keyed by the term lowercased. Spaces kept: FluidAudio
    // matches an alias against the transcript's words.
    // Sorted, because the boost session is rebuilt whenever this changes, and a Set's order does.
    static func aliases(_ heardAs: [String: [String]]) -> [String: [String]] {
        var all = mishears
        for (term, heard) in heardAs { all[term, default: []] += heard }
        return all.mapValues { Array(Set($0.map { $0.lowercased() })).sorted() }
    }

    // The rescorer replaces on acoustics alone, so a term that sounds like a common word takes it:
    // "code" became Xcode, "model" Modal, "error" Terraform, "strip" Stripe, "Claude and" Claude
    // Code. Same doctrine as `LLMCleaner.applyVocabulary`: a real English word is one the recognizer
    // heard right. Allowed through: a known mishear, the term with its spaces or slash
    // ("web hook", "CI CD"), and anything with a word that is not English ("Superbase", "We're
    // cell"). The word list has no plurals or possessives, so "models" and "code's" are checked by
    // their stem. Under four letters counts as English: `englishWords` omits them, and nearly all are.
    static func isMishear(_ original: String, of term: String, aliases: [String: [String]] = aliases([:])) -> Bool {
        let letters = { (text: String) in text.lowercased().filter(\.isLetter) }
        let bareTerm = term.hasSuffix("'s") ? String(term.dropLast(2)) : term
        let heard = letters(original.hasSuffix("'s") ? String(original.dropLast(2)) : original)
        if heard == letters(bareTerm) || aliases[bareTerm.lowercased()]?.contains { letters($0) == heard } == true { return true }
        return !original.lowercased().split(separator: " ").allSatisfy { word in
            // Apostrophes kept: "we're" stripped to "were" would pass for English.
            let bare = String(word.filter { $0.isLetter || $0 == "'" })
            let stems = [bare, bare.hasSuffix("'s") ? String(bare.dropLast(2)) : bare,
                         bare.hasSuffix("s") ? String(bare.dropLast()) : bare,
                         bare.hasSuffix("es") ? String(bare.dropLast(2)) : bare]
            return stems.contains { $0.count < 4 || LLMCleaner.englishWords.contains($0) }
        }
    }

    // Applies the kept replacements to whole words of `text`. The rescorer does not list them in
    // text order, so each takes the first run of words it matches that no other has claimed.
    // Punctuation around the heard words stays ("clod." → "Claude."). Nil when a run cannot be
    // found; the caller then uses the unboosted transcript, since a misplaced replacement corrupts
    // text and a skipped one does not.
    static func applying(_ replacements: [(original: String, term: String)], to text: String) -> String? {
        let core = { (word: Substring) in word.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        let words = text.split(separator: " ")
        var claimed: [(first: Int, last: Int, term: String)] = []
        for (original, term) in replacements {
            let wanted = original.split(separator: " ").map(core)
            guard !wanted.isEmpty,
                  let first = words.indices.first(where: { start in
                      start + wanted.count <= words.count
                          && !claimed.contains { start <= $0.last && $0.first <= start + wanted.count - 1 }
                          && zip(words[start...], wanted).allSatisfy { core($0) == $1 }
                  })
            else { return nil }
            claimed.append((first, first + wanted.count - 1, term))
        }
        var out: [String] = []
        var index = 0
        for (first, last, term) in claimed.sorted(by: { $0.first < $1.first }) {
            out += words[index..<first].map(String.init)
            let lead = words[first].prefix { $0.isPunctuation && $0 != "'" }
            let trail = words[last].reversed().prefix { $0.isPunctuation && $0 != "'" }
            out.append(String(lead) + term + String(trail.reversed()))
            index = last + 1
        }
        out += words[index...].map(String.init)
        return out.joined(separator: " ")
    }

    // Rebuilt only when the dictionary changes: building tokenizes every term.
    private func boostSession(for vocabulary: [String], aliases: [String: [String]]) async -> VocabularyBoostingSession? {
        guard let ctc, !vocabulary.isEmpty else { return nil }
        if vocabulary != boostTerms || aliases != boostAliases || boost == nil {
            boostTerms = vocabulary
            boostAliases = aliases
            boost = try? await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: Self.boostable(vocabulary).map {
                    CustomVocabularyTerm(text: $0, aliases: aliases[$0.lowercased()])
                }),
                ctcModels: ctc)
        }
        return boost
    }

    // Drops a spaced spelling of another term ("Bispr Blow" beside "BisprBlow"). Given both, the
    // rescorer picks the spaced one, which is the spelling the user does not want.
    static func boostable(_ vocabulary: [String]) -> [String] {
        let joined = Set(vocabulary.filter { !$0.contains(" ") }.map { $0.lowercased() })
        return vocabulary.filter {
            !$0.contains(" ") || !joined.contains($0.replacingOccurrences(of: " ", with: "").lowercased())
        }
    }
}
