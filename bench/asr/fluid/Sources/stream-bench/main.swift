// Would streaming cut the wait after release? Two modes over the same clips, runner contract from
// bench/asr/README.md plus a per-stage breakdown:
//
//   --mode batch   mirrors Parakeet.transcribe + Transcriber.finishParakeetSession: resample the
//                  whole clip, AsrManager.transcribe, VocabularyBoostingSession.rescore, guard.
//                  Its end-to-end `ms` is what `--transcribe` (results/app.jsonl) already measures;
//                  the mode exists for the per-stage breakdown and the incremental-CTC check.
//                  Also times the rescore's halves (CTC log-probs + spotting DP, then the rescorer)
//                  with a separately built spotter/rescorer, outside the wait.
//   --mode stream  SlidingWindowAsrManager fed in --feed-ms buffers at the file's own rate, waiting
//                  after each buffer only for windows that are already due ("as fast as it
//                  accepts"). CTC log-probs are computed during speech in the same 15 s / 2 s overlap
//                  chunks the spotter uses for long audio, so only the last chunk is left at
//                  release. The wait is finish() + last CTC chunk(s) + rescore + guard.
//
// The guard, alias table and replacement code are copies of Parakeet.swift so this measures the
// shipped decision, not FluidAudio's.
import AVFoundation
import FluidAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var mode = "batch"
var vocabPath: String?
var chunkS = 11.0, leftS = 2.0, rightS = 2.0
var feedMs = 100
var parallelTail = false
var files: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { guard !args.isEmpty else { fail("\(a) needs a value") }; return args.removeFirst() }
    switch a {
    case "--mode": mode = next()
    case "--vocab": vocabPath = next()
    case "--chunk": chunkS = Double(next())!
    case "--left": leftS = Double(next())!
    case "--right": rightS = Double(next())!
    case "--feed-ms": feedMs = Int(next())!
    case "--parallel": parallelTail = true
    default: files.append(a)
    }
}
guard !files.isEmpty else { fail("usage: stream-bench --mode batch|stream [--vocab f] [--chunk s --left s --right s] [--feed-ms n] [--parallel] files...") }

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

let results = FileHandle(fileDescriptor: dup(1))
dup2(2, 1)
func emit(_ obj: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    data.append(0x0A)
    results.write(data)
}
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Copies of Parakeet.swift's decision code

let englishWords: Set<String> = {
    guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n").lazy.filter { $0.count >= 4 }.map { $0.lowercased() })
}()
let mishears = ["claude": ["quad", "claw", "clawed", "clod"]]
// Built-in table only: the user's heard-as aliases are not applied here.
func aliasesFor() -> [String: [String]] {
    mishears.mapValues { Array(Set($0.map { $0.lowercased() })).sorted() }
}
func isMishear(_ original: String, of term: String, aliases: [String: [String]]) -> Bool {
    let letters = { (text: String) in text.lowercased().filter(\.isLetter) }
    let bareTerm = term.hasSuffix("'s") ? String(term.dropLast(2)) : term
    let heard = letters(original.hasSuffix("'s") ? String(original.dropLast(2)) : original)
    if heard == letters(bareTerm) || aliases[bareTerm.lowercased()]?.contains { letters($0) == heard } == true { return true }
    return !original.lowercased().split(separator: " ").allSatisfy { word in
        let bare = String(word.filter { $0.isLetter || $0 == "'" })
        let stems = [bare, bare.hasSuffix("'s") ? String(bare.dropLast(2)) : bare,
                     bare.hasSuffix("s") ? String(bare.dropLast()) : bare,
                     bare.hasSuffix("es") ? String(bare.dropLast(2)) : bare]
        return stems.contains { $0.count < 4 || englishWords.contains($0) }
    }
}
func applying(_ replacements: [(original: String, term: String)], to text: String) -> String? {
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
func boostable(_ vocabulary: [String]) -> [String] {
    let joined = Set(vocabulary.filter { !$0.contains(" ") }.map { $0.lowercased() })
    return vocabulary.filter {
        !$0.contains(" ") || !joined.contains($0.replacingOccurrences(of: " ", with: "").lowercased())
    }
}
func guarded(_ text: String, _ replacements: [VocabularyRescorer.RescoringResult], aliases: [String: [String]]) -> String {
    let kept = replacements.compactMap { r -> (String, String)? in
        guard let term = r.replacementWord, isMishear(r.originalWord, of: term, aliases: aliases) else { return nil }
        return (r.originalWord, term)
    }
    return applying(kept, to: text) ?? text
}

// MARK: - Audio

func readFile(_ path: String) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                               channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))),
            format.sampleRate)
}
func pcmBuffer(_ samples: ArraySlice<Float>, rate: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    b.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return b
}

// MARK: - Incremental CTC: the spotter's own long-audio chunking, run a chunk at a time

let ctcChunk = ASRConstants.maxModelSamples  // 15 s
let ctcOverlap = 32_000  // CtcKeywordSpotter.chunkOverlapSamples
let ctcStride = ctcChunk - ctcOverlap

func mergeOverlapFrame(_ a: [Float], _ b: [Float]) -> [Float] {
    let v = min(a.count, b.count)
    if v == 0 { return a }
    var out = [Float](repeating: 0, count: v)
    for j in 0..<v {
        let m = max(a[j], b[j])
        out[j] = m == -.infinity ? -.infinity : m + logf(expf(a[j] - m) + expf(b[j] - m)) - 0.69314718
    }
    return out
}

// Copy of Parakeet.swift's `ctcRanges`/`merged`, which `--self-check` guards against the spotter's
// one-shot log-probs. Nothing guards this copy: change both together.
final class CtcAccumulator {
    let spotter: CtcKeywordSpotter
    let empty = CustomVocabularyContext(terms: [])
    var chunks: [[[Float]]] = []
    var frameDuration = 0.0
    init(spotter: CtcKeywordSpotter) { self.spotter = spotter }

    // Chunk k is [k*stride, k*stride + 15 s): complete once that much audio exists, whatever the total.
    func catchUp(_ audio: ArraySlice<Float>) async throws {
        while chunks.count * ctcStride + ctcChunk <= audio.count {
            let start = chunks.count * ctcStride
            try await add(Array(audio[start..<start + ctcChunk]))
        }
    }
    // The rest, exactly as computeLogProbs would split the finished clip.
    func finish(_ audio: [Float]) async throws -> [[Float]] {
        if audio.count <= ctcChunk {
            chunks = []
            try await add(audio)
            return chunks[0]
        }
        var start = chunks.count * ctcStride
        while start < audio.count {
            try await add(Array(audio[start..<min(start + ctcChunk, audio.count)]))
            if start + ctcChunk >= audio.count { break }
            start += ctcStride
        }
        let overlapFrames = Int(Double(ctcOverlap) / 16_000 / frameDuration)
        var merged: [[Float]] = []
        for (i, lp) in chunks.enumerated() where !lp.isEmpty {
            if i == 0 { merged = lp; continue }
            let n = min(overlapFrames, merged.count, lp.count)
            for k in 0..<n { merged[merged.count - n + k] = mergeOverlapFrame(merged[merged.count - n + k], lp[k]) }
            if n < lp.count { merged += lp[n...] }
        }
        return merged
    }
    private func add(_ samples: [Float]) async throws {
        let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: empty)
        if chunks.isEmpty { frameDuration = r.frameDuration }
        chunks.append(r.logProbs)
    }
}

// One AVAudioConverter for the whole dictation, configured like FluidAudio's AudioConverter
// (Mastering, max quality), fed as the audio arrives so its filter state carries across buffers.
// Only built for non-16 kHz input (the 48 kHz clip copies); 16 kHz clips skip it untested.
final class StreamingResampler {
    let converter: AVAudioConverter
    let inFormat: AVAudioFormat, outFormat: AVAudioFormat
    init(from rate: Double) throws {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }
    func push(_ samples: ArraySlice<Float>, end: Bool) throws -> [Float] {
        let input = samples.isEmpty ? nil : pcmBuffer(samples, rate: inFormat.sampleRate)
        var given = input == nil
        let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count / 2 + 8192))!
        var result: [Float] = []
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, st in
                if !given { given = true; st.pointee = .haveData; return input }
                st.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw error ?? NSError(domain: "resample", code: 1) }
            result += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return result
    }
}

// Applies SlidingWindowTokenUpdate revisions to keep the job's global token timings.
actor TokenLog {
    var tokens: [TokenTiming] = []
    var windows = 0
    func apply(_ u: SlidingWindowTokenUpdate) {
        tokens = Array(tokens.prefix(u.revision.retainedTokenCount)) + u.tokens
        if !u.revision.isTerminal { windows += 1 }
    }
}

// MARK: - Run

let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let modelDir = try await AsrModels.download(version: .ultra)
        let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let models = try await AsrModels.load(from: modelDir, version: .ultra)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let layers = await asr.decoderLayerCount

        let lines = try vocabPath.map {
            try String(contentsOfFile: $0, encoding: .utf8).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        let aliases = aliasesFor()
        let session = try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: boostable(lines).map {
                CustomVocabularyTerm(text: $0, aliases: aliases[$0.lowercased()])
            }),
            ctcModels: ctcModels)
        // Same parameters VocabularyBoostingSession.rescore derives (rescoreParameters is internal).
        let vocab = session.vocabulary
        let size = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
        let cbw = session.thresholds.cbw ?? size.cbw
        let minSim = max(session.thresholds.minSimilarity ?? size.minSimilarity, vocab.minSimilarity)
        let margin = session.thresholds.marginSeconds
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocab, ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let converter = AudioConverter()
        let swConfig = SlidingWindowAsrConfig(
            chunkSeconds: chunkS, hypothesisChunkSeconds: 1, leftContextSeconds: leftS,
            rightContextSeconds: rightS, minContextForConfirmation: 10, confirmationThreshold: 0.85)
        log("vocab terms=\(vocab.terms.count) cbw=\(cbw) minSim=\(minSim) margin=\(margin) mode=\(mode) sw=\(chunkS)/\(leftS)/\(rightS) parallel=\(parallelTail)")

        func batch(_ path: String) async throws -> [String: Any] {
            let (raw, rate) = try readFile(path)
            let clock = ContinuousClock()
            var t = clock.now
            let audio = rate == 16_000 ? raw : try converter.resample(raw, from: rate)
            let resampleMs = ms(clock.now - t)
            t = clock.now
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try await asr.transcribe(audio, decoderState: &state)
            let asrMs = ms(clock.now - t)
            t = clock.now
            let rescored = await session.rescore(
                text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: audio)
            let sessionMs = ms(clock.now - t)
            t = clock.now
            let text = guarded(result.text, rescored?.replacements ?? [], aliases: aliases)
            let guardMs = ms(clock.now - t)

            // The halves, outside the wait.
            t = clock.now
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: CustomVocabularyContext(terms: []))
            let ctcMs = ms(clock.now - t)
            t = clock.now
            _ = spotter.spotKeywordsFromLogProbs(logProbs: spot.logProbs, frameDuration: spot.frameDuration, customVocabulary: vocab)
            let dpMs = ms(clock.now - t)
            t = clock.now
            let out = rescorer.ctcTokenRescore(
                transcript: result.text, tokenTimings: result.tokenTimings ?? [], logProbs: spot.logProbs,
                frameDuration: spot.frameDuration, cbw: cbw, marginSeconds: margin, minSimilarity: minSim)
            let rescoreMs = ms(clock.now - t)
            // Incremental CTC must reproduce the batch log-probs exactly.
            let acc = CtcAccumulator(spotter: spotter)
            try await acc.catchUp(audio[...])
            let inc = try await acc.finish(audio)
            var maxDiff: Float = 0
            if inc.count == spot.logProbs.count {
                for (a, b) in zip(inc, spot.logProbs) { for (x, y) in zip(a, b) { maxDiff = max(maxDiff, abs(x - y)) } }
            } else { maxDiff = .infinity }
            let splitText = guarded(result.text, out.replacements, aliases: aliases)
            return [
                "text": text, "raw": result.text,
                "ms": Int((resampleMs + asrMs + sessionMs + guardMs).rounded()),
                "resample_ms": round1(resampleMs), "asr_ms": round1(asrMs), "rescore_total_ms": round1(sessionMs),
                "guard_ms": round1(guardMs), "ctc_infer_ms": round1(ctcMs), "spot_dp_ms": round1(dpMs),
                "rescorer_ms": round1(rescoreMs), "split_matches": splitText == text,
                "incremental_ctc_maxdiff": maxDiff.isFinite ? Double(maxDiff) : -1, "seconds": round1(Double(audio.count) / 16_000),
            ]
        }

        func stream(_ path: String) async throws -> [String: Any] {
            let (raw, rate) = try readFile(path)
            let resampler = rate == 16_000 ? nil : try StreamingResampler(from: rate)
            let setupStart = ContinuousClock.now
            let sw = SlidingWindowAsrManager(config: swConfig)
            try await sw.loadModels(models)
            let log = TokenLog()
            let updates = await sw.tokenUpdates
            let reader = Task { for try await u in updates { await log.apply(u) } }
            try await sw.startStreaming()
            let setupMs = ms(ContinuousClock.now - setupStart)
            let acc = CtcAccumulator(spotter: spotter)

            let step = Int(rate) * feedMs / 1000
            let chunk16 = Int(chunkS * 16_000), right16 = Int(rightS * 16_000)
            var fed = 0
            var audio16: [Float] = []
            let clock = ContinuousClock()
            var stalls = 0.0
            while fed < raw.count {
                let end = min(fed + step, raw.count)
                let piece = try resampler?.push(raw[fed..<end], end: false) ?? Array(raw[fed..<end])
                fed = end
                audio16 += piece
                if !piece.isEmpty { await sw.streamAudio(pcmBuffer(piece[...], rate: 16_000)) }
                let due = audio16.count >= chunk16 + right16 ? (audio16.count - chunk16 - right16) / chunk16 + 1 : 0
                let t = clock.now
                while await log.windows < due {
                    try await Task.sleep(for: .milliseconds(1))
                    if clock.now - t > .seconds(20) { fail("window never arrived in \(path)") }
                }
                try await acc.catchUp(audio16[...])
                stalls += ms(clock.now - t)
            }
            let windowsDuring = await log.windows
            let ctcDuring = acc.chunks.count

            // Release.
            let t0 = clock.now
            let tail = try resampler?.push([], end: true) ?? []
            audio16 += tail
            if !tail.isEmpty { await sw.streamAudio(pcmBuffer(tail[...], rate: 16_000)) }
            let resampleTailMs = ms(clock.now - t0)
            var asrTailMs = 0.0, ctcTailMs: Double?
            let text: String
            let logProbs: [[Float]]
            var t = clock.now
            if parallelTail {
                async let finished = sw.finish()
                async let lp = acc.finish(audio16)
                (text, logProbs) = try await (finished, lp)
                asrTailMs = ms(clock.now - t)
            } else {
                text = try await sw.finish()
                asrTailMs = ms(clock.now - t)
                t = clock.now
                logProbs = try await acc.finish(audio16)
                ctcTailMs = ms(clock.now - t)
            }
            _ = try? await reader.value
            let tokens = await log.tokens
            t = clock.now
            let out = rescorer.ctcTokenRescore(
                transcript: text, tokenTimings: tokens, logProbs: logProbs,
                frameDuration: acc.frameDuration, cbw: cbw, marginSeconds: margin, minSimilarity: minSim)
            let rescoreMs = ms(clock.now - t)
            t = clock.now
            let final = vocab.terms.isEmpty ? text : guarded(text, out.replacements, aliases: aliases)
            let guardMs = ms(clock.now - t)
            let wait = ms(clock.now - t0)
            // The streamed resample must equal the one-shot resample the app does on release. Only
            // checked for non-16 kHz input; on 16 kHz clips resample_maxdiff is 0 by construction.
            var resampleDiff: Float = 0
            if rate != 16_000 {
                let whole = try converter.resample(raw, from: rate)
                if whole.count == audio16.count {
                    for (a, b) in zip(whole, audio16) { resampleDiff = max(resampleDiff, abs(a - b)) }
                } else { resampleDiff = Float(whole.count - audio16.count) * 1000 }
            }
            var rec: [String: Any] = [
                "text": final, "raw": text, "ms": Int(wait.rounded()),
                "resample_tail_ms": round1(resampleTailMs), "resample_maxdiff": Double(resampleDiff),
                "rescorer_ms": round1(rescoreMs),
                "guard_ms": round1(guardMs), "windows_during": windowsDuring, "windows_total": await log.windows,
                "ctc_chunks_during": ctcDuring, "ctc_chunks_total": acc.chunks.count,
                "stall_ms_during": round1(stalls), "tokens": tokens.count, "setup_ms": round1(setupMs),
                "seconds": round1(Double(audio16.count) / 16_000),
            ]
            // In parallel the ASR and CTC tails overlap, so only their combined wall time is real.
            if let ctcTailMs {
                rec["asr_tail_ms"] = round1(asrTailMs)
                rec["ctc_tail_ms"] = round1(ctcTailMs)
            } else {
                rec["tail_ms"] = round1(asrTailMs)
            }
            return rec
        }

        let run = mode == "stream" ? stream : batch
        _ = try await run(files[0])  // warm-up, discarded
        for file in files {
            var rec = try await run(file)
            rec["file"] = (file as NSString).lastPathComponent
            emit(rec)
        }
    } catch {
        fail("error: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
