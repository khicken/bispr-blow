import Foundation
import LocalLLMClient
import LocalLLMClientLlama
import LocalLLMClientMLX

/// In-process inference. The only file that imports the inference library — everything else reaches
/// it through `LLMCleaner.Endpoint`, so changing runtime touches this file and the endpoint list.
///
/// It exists because LM Studio is a dependency the app cannot satisfy on the user's behalf: without
/// it every dictation degrades to unpunctuated `ruleClean`, and it means running a separate
/// third-party app plus `lms server start` as its own process. What LM Studio was doing for free —
/// loading the model once and keeping it resident — is what `client` below does instead.
///
/// llama.cpp rather than MLX, and that was not the first choice. MLX is the faster integration on
/// paper (native SwiftPM, weights already on disk in MLX format) but mlx-swift's own README states
/// SwiftPM on the command line cannot build its Metal shaders, and a missing `default.metallib`
/// makes MLX abort the process instead of throwing — so it cannot even fall back. llama.cpp ships a
/// precompiled xcframework whose shaders were built in CI, which is why `swift build` works here
/// with no Metal Toolchain and no change to build.sh. It also reaches Linux, which MLX does not.
actor LocalEngine {
    static let shared = LocalEngine()

    private enum Backend {
        case llama(LlamaClient)
        case mlx(MLXClient)
    }

    private var client: Backend?
    private var loadedID: String?

    /// MLX aborts the whole process — no thrown error, no fallback — when its metallib is
    /// missing, so MLX models stay invisible unless the library is where MLX will look. Two
    /// homes, matching MLX's search order: `mlx.metallib` beside the executable (the CLI binary
    /// in .build/release — codesign refuses that spot inside the app bundle), or
    /// `default.metallib` in the Resources/mlx-swift_Cmlx.bundle SwiftPM bundle (the app).
    /// build.sh compiles and places both.
    static var mlxAvailable: Bool {
        let fm = FileManager.default
        if let exe = Bundle.main.executableURL,
           fm.fileExists(atPath: exe.deletingLastPathComponent()
               .appendingPathComponent("mlx.metallib").path) {
            return true
        }
        guard let resources = Bundle.main.resourceURL else { return false }
        return fm.fileExists(atPath: resources
            .appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib").path)
    }

    /// Directories scanned for models, in preference order. `Application Support` is where the
    /// download-on-setup step lands them; LM Studio's directory is read too so a machine that already
    /// has weights is not asked to download them twice.
    private static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/BluejayWispr/models"),
            home.appendingPathComponent(".lmstudio/models"),
        ]
    }

    /// Every GGUF on disk, as (id, file). The id is the filename without its extension so the
    /// existing `smallFamilies` / `carefulFamilies` matching in `LLMCleaner` works on it unchanged:
    /// "Qwen3-0.6B-Q4_K_M" lowercases to something containing "qwen3-0.6b", which is what Fast
    /// already looks for. Fast/Accurate therefore needs no knowledge that the transport changed.
    ///
    /// Multimodal projector files are skipped — they are companions to a model, not a model.
    /// MLX model directories (config.json plus safetensors) are listed ahead of GGUF files on
    /// purpose: the ids overlap ("Qwen3-0.6B-MLX-4bit" and "Qwen3-0.6B-Q4_K_M" both match the
    /// qwen3-0.6b family) and `firstModel` takes the first hit — benched, the MLX weights hold
    /// 96/85 recall/quality where the GGUF quants sit at 77-81 quality.
    static func installedModels() -> [(id: String, url: URL)] {
        let fm = FileManager.default
        var mlx: [(id: String, url: URL)] = []
        var gguf: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for root in Self.searchRoots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
                          let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
                          files.contains(where: { $0.pathExtension == "safetensors" })
                    else { continue }
                    walker.skipDescendants()
                    if mlxAvailable, seen.insert(url.lastPathComponent.lowercased()).inserted {
                        mlx.append((id: url.lastPathComponent, url: url))
                    }
                    continue
                }
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                guard !id.lowercased().contains("mmproj") else { continue }
                if seen.insert(id.lowercased()).inserted { gguf.append((id: id, url: url)) }
            }
        }
        return mlx + gguf
    }

    /// Loads the model if it is not already resident. Separate from `complete` so `warmUp()` can pay
    /// the load cost at launch — it is the one genuinely slow part, and paying it inside a dictation
    /// is the cold stall the deadline guard exists to survive rather than absorb.
    func load(id: String) async throws -> Bool {
        if loadedID == id, client != nil { return false }
        guard let model = Self.installedModels().first(where: { $0.id == id }) else {
            throw Failure.notInstalled(id)
        }
        let started = Date()
        // `context` has to hold the static prefix plus the transcript plus the reply. The low-touch
        // prefix alone carries a 202-word demonstration, and dictations run 200-300 words, so the
        // 2048 default would silently truncate the prompt — losing the user's words, which is the
        // one outcome this app treats as worse than any other.
        //
        // 8192 holds the ~1378-token prefix plus a 300-word dictation plus the reply with room to
        // spare — the KV trim in our LocalLLMClient copy runs in release now, so the context no
        // longer grows per call and this is a size calculation again, not a mitigation.
        // WISPR_LLAMA_VERBOSE=1 makes llama.cpp print its backend and layer offload counts. Worth a
        // line permanently: whether the model is on the GPU or silently on the CPU is invisible from
        // latency alone, and guessing at it produced a wrong 2.6x conclusion once already.
        // penaltyRepeat defaults to 1.1, which punishes echoing recent tokens — backwards for
        // cleanup, where a faithful answer repeats most of the transcript. Benched at 1.0 vs 1.1
        // on both quants: no measurable difference (run noise dominates), kept at the neutral 1.0
        // because the task copies text by design.
        if model.url.pathExtension.lowercased() == "gguf" {
            client = .llama(try await LocalLLMClient.llama(
                url: model.url,
                parameter: .init(
                    context: 8192, temperature: 0.2, penaltyRepeat: 1.0,
                    options: .init(verbose: ProcessInfo.processInfo.environment["WISPR_LLAMA_VERBOSE"] != nil))))
        } else {
            client = .mlx(try await LocalLLMClient.mlx(
                url: model.url,
                parameter: .init(maxTokens: 2048, temperature: 0.2)))
        }
        loadedID = id
        logLine("local model loaded \(id) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return true
    }

    /// One completion. `messages` is the same `[[String: String]]` the HTTP path sends, so both
    /// transports run byte-identical prompts and comparing them is honest.
    func complete(id: String, messages: [[String: String]]) async throws -> String {
        _ = try await load(id: id)
        guard let client else { throw Failure.notInstalled(id) }

        let chat: [LLMInput.Message] = messages.compactMap { message in
            guard let content = message["content"] else { return nil }
            switch message["role"] {
            case "system": return .system(content)
            case "assistant": return .assistant(content)
            default: return .user(content)
            }
        }

        let started = Date()
        var output = ""
        switch client {
        case .llama(let client):
            for try await chunk in try client.textStream(from: .chat(chat)) {
                output += chunk
                // A model that starts looping must not outrun the deadline guard by streaming
                // forever. Generous against any real dictation — the longest bench case cleans to
                // ~1.7k chars. Character ceiling rather than a token budget; tighten if a real
                // case nears it.
                if output.count > 16_000 { break }
            }
        case .mlx(let client):
            // Metal asserts — and aborts the whole app — when a generation is cancelled mid
            // command-buffer commit, so a deadline miss must never cancel MLX. The stream is
            // drained in a detached task that outer cancellation cannot reach; the deadline
            // returns rules while the abandoned generation finishes quietly and is discarded.
            let stream = try await client.textStream(from: .chat(chat))
            output = await Task.detached {
                var out = ""
                for await chunk in stream {
                    out += chunk
                    if out.count > 16_000 { break }
                }
                return out
            }.value
        }
        logLine("local completion \(Int(Date().timeIntervalSince(started) * 1000))ms \(output.count)chars")
        return output
    }

    enum Failure: Error, LocalizedError {
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let id): return "Model \(id) is not installed."
            }
        }
    }
}
