// Parakeet TDT through FluidAudio, batch mode, per the runner contract in bench/asr/README.md.
// --vocab adds FluidAudio's CTC keyword-spotting rescorer (a second, 110M CTC encoder).
import FluidAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var modelName = "v2"
var vocabPath: String?
var files: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--model", "--vocab":
        guard !args.isEmpty else { fail("\(a) needs a value") }
        if a == "--model" { modelName = args.removeFirst() } else { vocabPath = args.removeFirst() }
    default: files.append(a)
    }
}
guard !files.isEmpty else { fail("usage: fluid-runner --model v2|v3|ultra|phonon2 [--vocab vocab.txt] files...") }

let version: AsrModelVersion
switch modelName {
case "v2": version = .v2
case "v3": version = .v3
case "ultra": version = .ultra
case "phonon2": version = .phonon2
default: fail("unknown model \(modelName)")
}

// Same table as Parakeet.mishears in the app.
let aliases: [String: [String]] = [
    "Claude": ["quad", "claw", "clawed", "clod"],
]

func ms(since start: ContinuousClock.Instant) -> Int {
    let d = ContinuousClock.now - start
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

// CoreML's E5RT writes compile errors to fd 1, which would corrupt the JSON lines. Keep the real
// stdout for results and point fd 1 at stderr.
let results = FileHandle(fileDescriptor: dup(1))
dup2(2, 1)

func emit(_ obj: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    data.append(0x0A)
    results.write(data)
}

let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do {
        // Download outside the timed load so load_ms is the cold load from the cache.
        let modelDir = try await AsrModels.download(version: version)
        var ctcModels: CtcModels?
        if vocabPath != nil { ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m) }

        let loadStart = ContinuousClock.now
        let models = try await AsrModels.load(from: modelDir, version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        var session: VocabularyBoostingSession?
        if let vocabPath, let ctcModels {
            let lines = try String(contentsOfFile: vocabPath, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let terms = lines.map { CustomVocabularyTerm(text: $0, aliases: aliases[$0]) }
            session = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctcModels)
        }
        FileHandle.standardError.write("load_ms=\(ms(since: loadStart))\n".data(using: .utf8)!)

        let converter = AudioConverter()
        let layers = await asr.decoderLayerCount
        func run(_ samples: [Float]) async throws -> String {
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try await asr.transcribe(samples, decoderState: &state)
            guard let session else { return result.text }
            let out = await session.rescore(
                text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
            return out?.text ?? result.text
        }

        _ = try await run(try converter.resampleAudioFile(path: files[0]))  // warm-up, discarded
        for file in files {
            let samples = try converter.resampleAudioFile(path: file)
            let start = ContinuousClock.now
            let text = try await run(samples)
            emit(["file": (file as NSString).lastPathComponent, "text": text, "ms": ms(since: start)])
        }
    } catch {
        fail("error: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
