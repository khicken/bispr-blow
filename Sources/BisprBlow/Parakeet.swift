import AVFoundation
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
    private var boost: (session: VocabularyBoostingSession, rescorer: VocabularyRescorer)?
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

    // `samples` is 16kHz mono, and `ctc` the CTC chunks `ParakeetStream` finished during speech.
    // Nil is a failure; the words are lost, so the caller has to say so.
    func transcribe(_ samples: [Float], ctc: [CtcKeywordSpotter.SpotKeywordsResult] = [],
                    vocabulary: [String], heardAs: [String: [String]]) async -> String? {
        guard let asr else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await asr.transcribe(samples, decoderState: &state)
            let aliases = Self.aliases(heardAs)
            guard let boost = await boostSession(for: vocabulary, aliases: aliases) else { return result.text }
            let replacements = await rescore(result, samples, ctc: ctc, boost: boost)
            let kept = replacements.compactMap { r -> (String, String)? in
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

    // `VocabularyBoostingSession.rescore`, from log-probs mostly computed during speech: the chunks
    // in `ctc`, then whatever audio is left. Like it, a CTC failure costs the boost, not the words.
    private func rescore(_ result: ASRResult, _ samples: [Float], ctc: [CtcKeywordSpotter.SpotKeywordsResult],
                         boost: (session: VocabularyBoostingSession, rescorer: VocabularyRescorer)) async
        -> [VocabularyRescorer.RescoringResult] {
        let timings = result.tokenTimings ?? []
        guard !timings.isEmpty, !samples.isEmpty else { return [] }
        let logProbs: [[Float]], frameDuration: Double
        do {
            (logProbs, frameDuration) = try await self.logProbs(samples, ctc: ctc)
        } catch {
            logLine("parakeet: vocabulary rescoring failed: \(error)")
            return []
        }
        guard !logProbs.isEmpty else { return [] }
        // `VocabularyBoostingSession.rescoreParameters`, which is internal.
        let session = boost.session
        let size = ContextBiasingConstants.rescorerConfig(forVocabSize: session.vocabulary.terms.count)
        return boost.rescorer.ctcTokenRescore(
            transcript: result.text, tokenTimings: timings, logProbs: logProbs, frameDuration: frameDuration,
            cbw: session.thresholds.cbw ?? size.cbw, marginSeconds: session.thresholds.marginSeconds,
            minSimilarity: max(session.thresholds.minSimilarity ?? size.minSimilarity, session.vocabulary.minSimilarity)
        ).replacements
    }

    // What `CtcKeywordSpotter.spotKeywordsWithLogProbs` gives for `samples`, from the chunks
    // already done plus the rest.
    private func logProbs(_ samples: [Float], ctc: [CtcKeywordSpotter.SpotKeywordsResult]) async throws
        -> (logProbs: [[Float]], frameDuration: Double) {
        var chunks = ctc
        for range in Self.ctcRanges(samples.count).dropFirst(chunks.count) {
            chunks.append(try await ctcChunk(Array(samples[range])))
        }
        return Self.merged(chunks)
    }

    // One chunk of the dictionary's CTC pass. No vocabulary: the log-probs do not depend on it.
    func ctcChunk(_ samples: [Float]) async throws -> CtcKeywordSpotter.SpotKeywordsResult {
        guard let ctc else { throw CancellationError() }
        return try await CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
            .spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: CustomVocabularyContext(terms: []))
    }

    // Copies of two FluidAudio internals, so the CTC pass can run a chunk at a time while the user
    // speaks: `CtcKeywordSpotter.computeLogProbsChunked`'s 15 s windows overlapping by
    // `chunkOverlapSamples`, and `mergeOverlapFrame`. --self-check fails if they drift.
    static let ctcWindow = ASRConstants.maxModelSamples
    static let ctcStride = ctcWindow - 32_000

    static func ctcRanges(_ count: Int) -> [Range<Int>] {
        var ranges = [0..<min(ctcWindow, count)]
        while ranges.last!.upperBound < count {
            let start = ranges.last!.lowerBound + ctcStride
            ranges.append(start..<min(start + ctcWindow, count))
        }
        return ranges
    }

    static func merged(_ chunks: [CtcKeywordSpotter.SpotKeywordsResult]) -> (logProbs: [[Float]], frameDuration: Double) {
        guard let first = chunks.first else { return ([], 0) }
        if chunks.count == 1 { return (first.logProbs, first.frameDuration) }
        guard first.frameDuration > 0 else { return ([], 0) }
        let overlapFrames = Int(Double(32_000) / Double(ASRConstants.sampleRate) / first.frameDuration)
        var merged: [[Float]] = []
        for chunk in chunks where !chunk.logProbs.isEmpty {
            guard !merged.isEmpty else { merged = chunk.logProbs; continue }
            let overlap = min(overlapFrames, merged.count, chunk.logProbs.count)
            for i in 0..<overlap {
                let at = merged.count - overlap + i
                merged[at] = zip(merged[at], chunk.logProbs[i]).map { a, b in
                    let m = max(a, b)
                    return m == -Float.infinity ? -Float.infinity : m + logf(expf(a - m) + expf(b - m)) - Float(0.69314718)
                }
            }
            merged += chunk.logProbs[overlap...]
        }
        return (merged, first.frameDuration)
    }

    // --self-check: the incremental path beside FluidAudio's over the whole clip, which it must
    // reproduce exactly — the log-probs, and the replacements `VocabularyBoostingSession.rescore` makes.
    func checkIncremental(_ samples: [Float], ctc: [CtcKeywordSpotter.SpotKeywordsResult], vocabulary: [String])
        async throws -> (sameLogProbs: Bool, incremental: [String], whole: [String]) {
        guard let asr, let boost = await boostSession(for: vocabulary, aliases: Self.aliases([:])) else {
            throw CancellationError()
        }
        let merged = try await logProbs(samples, ctc: ctc)
        let whole = try await ctcChunk(samples)
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        let describe = { (r: VocabularyRescorer.RescoringResult) in "\(r.originalWord) → \(r.replacementWord ?? "-")" }
        let rescored = await boost.session.rescore(
            text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        return (merged.logProbs == whole.logProbs && merged.frameDuration == whole.frameDuration,
                await rescore(result, samples, ctc: ctc, boost: boost).map(describe),
                (rescored?.replacements ?? []).map(describe))
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
    private func boostSession(for vocabulary: [String], aliases: [String: [String]]) async
        -> (session: VocabularyBoostingSession, rescorer: VocabularyRescorer)? {
        guard let ctc, !vocabulary.isEmpty else { return nil }
        if vocabulary != boostTerms || aliases != boostAliases || boost == nil {
            boostTerms = vocabulary
            boostAliases = aliases
            boost = nil
            if let session = try? await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: Self.boostable(vocabulary).map {
                    CustomVocabularyTerm(text: $0, aliases: aliases[$0.lowercased()])
                }),
                ctcModels: ctc),
               let rescorer = try? await VocabularyRescorer.create(
                spotter: CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count),
                vocabulary: session.vocabulary, ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctc.variant)) {
                boost = (session, rescorer)
            }
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

// The part of a Parakeet dictation that can run before release, run during speech: the resample to
// 16kHz, and the dictionary's CTC pass over each 15 s chunk as soon as it is whole. Both give
// exactly what running them on release gave (--self-check), so release pays only for the last
// chunk. `append` runs on the capture queue.
final class ParakeetStream: @unchecked Sendable {
    private let lock = NSLock()
    private var rate = 0.0
    private var converter: AVAudioConverter?
    private var audio: [Float] = []
    private var failed = false
    private var queued = 0
    private let chunks: AsyncStream<[Float]>.Continuation
    private let ctc: Task<[CtcKeywordSpotter.SpotKeywordsResult], Error>

    init() {
        let (stream, chunks) = AsyncStream<[Float]>.makeStream()
        self.chunks = chunks
        ctc = Task {
            var done: [CtcKeywordSpotter.SpotKeywordsResult] = []
            for await samples in stream {
                try Task.checkCancellation()
                done.append(try await Parakeet.shared.ctcChunk(samples))
            }
            return done
        }
    }

    // Channel 0 only, as `AudioRecorder.measure` does. A new sample rate (a device change
    // mid-dictation) flushes the converter and starts another, so no audio is resampled as if it
    // were at the other rate.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.withLock {
            if buffer.format.sampleRate != rate {
                flush()
                rate = buffer.format.sampleRate
                converter = rate == 16_000 ? nil : Self.converter(from: rate)
                if rate != 16_000, converter == nil { failed = true }
            }
            if converter != nil { convert(samples, end: false) } else if rate == 16_000 { audio += samples }
            while queued * Parakeet.ctcStride + Parakeet.ctcWindow <= audio.count {
                let start = queued * Parakeet.ctcStride
                chunks.yield(Array(audio[start..<start + Parakeet.ctcWindow]))
                queued += 1
            }
        }
    }

    // The 16kHz audio and the CTC chunks finished so far. Nil when resampling failed.
    func finish() async -> (audio: [Float], ctc: [CtcKeywordSpotter.SpotKeywordsResult])? {
        let captured = lock.withLock { () -> [Float]? in
            flush()
            chunks.finish()
            defer { audio = [] }
            return failed ? nil : audio
        }
        let done = (try? await ctc.value) ?? []
        return captured.map { ($0, done) }
    }

    // Returns once nothing started for this dictation is still running.
    func cancel() async {
        lock.withLock { chunks.finish() }
        ctc.cancel()
        _ = try? await ctc.value
    }

    // Configured as FluidAudio's `AudioConverter.resample`, which this replaces.
    private static func converter(from rate: Double) -> AVAudioConverter? {
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to)
        else { return nil }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        return converter
    }

    private func flush() {
        if converter != nil { convert([], end: true) }
        converter = nil
    }

    private func convert(_ samples: [Float], end: Bool) {
        guard let converter, !failed else { return }
        var input: AVAudioPCMBuffer?
        if !samples.isEmpty {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count))
            else { failed = true; return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            input = buffer
        }
        var given = input == nil
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: AVAudioFrameCount(Double(samples.count) * 16_000 / rate) + 8192)
        else { failed = true; return }
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if !given {
                    given = true
                    status.pointee = .haveData
                    return input
                }
                status.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                logLine("parakeet resample failed: \(error.map { "\($0)" } ?? "unknown")")
                failed = true
                return
            }
            audio += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            if status == .endOfStream || status == .inputRanDry { break }
        }
    }
}
