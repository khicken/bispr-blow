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

    var isReady: Bool { asr != nil }

    // Fetches the models on first run (about 700MB into Application Support/FluidAudio) and loads
    // them. Until this finishes, or if it fails, `Transcriber` stays on Apple's recognizer.
    func load() async {
        guard asr == nil else { return }
        do {
            let start = Date()
            let dir = try await AsrModels.download(version: .ultra)
            let models = try await AsrModels.load(from: dir, version: .ultra)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            decoderLayers = await manager.decoderLayerCount
            ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            asr = manager
            // The first call through a freshly loaded CoreML model pays for its own setup; a second
            // of silence keeps that off the first real dictation.
            _ = await transcribe(Array(repeating: 0, count: 16_000), vocabulary: [])
            logLine("parakeet ready in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        } catch {
            logLine("parakeet unavailable, staying on Apple: \(error)")
        }
    }

    // `samples` is 16kHz mono. Nil is a failure; the words are lost, so the caller has to say so.
    func transcribe(_ samples: [Float], vocabulary: [String]) async -> String? {
        guard let asr else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await asr.transcribe(samples, decoderState: &state)
            guard let session = await boostSession(for: vocabulary) else { return result.text }
            let rescored = await session.rescore(
                text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
            return rescored?.text ?? result.text
        } catch {
            logLine("parakeet transcribe failed: \(error)")
            return nil
        }
    }

    // Mishears of a term that real words own, so only acoustics can tell them apart: Ultra writes
    // "clod" for Claude, and nothing downstream respells a real word.
    private static let mishears = ["Claude": ["quad", "claw", "clawed", "clod"]]

    // Rebuilt only when the dictionary changes: building tokenizes every term.
    private func boostSession(for vocabulary: [String]) async -> VocabularyBoostingSession? {
        guard let ctc, !vocabulary.isEmpty else { return nil }
        if vocabulary != boostTerms || boost == nil {
            boostTerms = vocabulary
            boost = try? await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: Self.boostable(vocabulary).map {
                    CustomVocabularyTerm(text: $0, aliases: Self.mishears[$0])
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
