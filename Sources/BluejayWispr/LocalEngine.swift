import Foundation
import LocalLLMClient
import LocalLLMClientLlama

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

    private var client: LlamaClient?
    private var loadedID: String?

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
    static func installedModels() -> [(id: String, url: URL)] {
        let fm = FileManager.default
        var found: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for root in Self.searchRoots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                guard !id.lowercased().contains("mmproj") else { continue }
                if seen.insert(id.lowercased()).inserted { found.append((id: id, url: url)) }
            }
        }
        return found
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
        client = try await LocalLLMClient.llama(
            url: model.url,
            parameter: .init(
                context: 8192, temperature: 0.2, penaltyRepeat: 1.0,
                options: .init(verbose: ProcessInfo.processInfo.environment["WISPR_LLAMA_VERBOSE"] != nil)))
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
        for try await chunk in try client.textStream(from: .chat(chat)) {
            output += chunk
            // A model that starts looping must not outrun the deadline guard by streaming forever.
            // Generous against any real dictation — the longest bench case cleans to ~1.7k chars.
            // ponytail: character ceiling rather than a token budget, tighten if a real case nears it.
            if output.count > 16_000 { break }
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
