import Foundation
import LocalLLMClient
import LocalLLMClientLlama
import LocalLLMClientMLX

// In-process inference. The only file that imports the inference library — everything else reaches
// it through `LLMCleaner.Endpoint`, so changing runtime touches this file and the endpoint list. It
// exists because LM Studio was a dependency the app cannot satisfy on the user's behalf: without it
// every dictation degrades to unpunctuated `ruleClean`. Loading the model once and keeping it
// resident is what `client` below does instead.
//
// llama.cpp rather than MLX for the build: mlx-swift's README says SwiftPM on the command line
// cannot build its Metal shaders, and a missing metallib makes MLX abort the process instead of
// throwing, so it cannot even fall back. llama.cpp ships a precompiled xcframework, and it reaches
// Linux.
actor LocalEngine {
    static let shared = LocalEngine()

    private enum Backend {
        case llama(LlamaClient)
        case mlx(MLXClient)
    }

    private var client: Backend?
    private var loadedID: String?

    // MLX aborts the whole process — no throw, no fallback — when its metallib is missing, so MLX
    // models stay invisible unless the library is where MLX will look. Two homes, matching MLX's
    // search order: `mlx.metallib` beside the executable (codesign refuses that spot inside the app
    // bundle), or `default.metallib` in the SwiftPM resource bundle. build.sh places both.
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

    // Directories scanned for models, in preference order. Home first, so a hand-placed or
    // downloaded model still wins. The bundle one lets the app be dragged out of a .dmg and work,
    // with no write outside /Applications. /Library is still read, because a machine that took the
    // .pkg already has weights there. LM Studio's directory is read for the same reason.
    private static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/BisprBlow/models"),
            Bundle.main.resourceURL?.appendingPathComponent("models"),
            URL(fileURLWithPath: "/Library/Application Support/BisprBlow/models"),
            home.appendingPathComponent(".lmstudio/models"),
        ].compactMap { $0 }
    }

    // Every model on disk, as (id, file). The id is the filename without its extension, so
    // `smallFamilies` / `carefulFamilies` matching works on it unchanged and Fast/Accurate needs no
    // knowledge that the transport changed. Multimodal projector files are skipped. MLX directories
    // are listed ahead of GGUF files on purpose: the ids overlap and `firstModel` takes the first
    // hit, and benched the MLX weights hold 96/85 recall/quality where GGUF quants sit at 77-81.
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

    // Loads the model if it is not resident. Separate from `complete` so `warmUp()` can pay the load
    // cost at launch rather than inside a dictation's deadline.
    func load(id: String) async throws -> Bool {
        if loadedID == id, client != nil { return false }
        guard let model = Self.installedModels().first(where: { $0.id == id }) else {
            throw Failure.notInstalled(id)
        }
        let started = Date()
        // `context` has to hold the static prefix plus the transcript plus the reply. The low-touch
        // prefix alone carries a 202-word demonstration and dictations run 200-300 words, so the
        // 2048 default would silently truncate the prompt. 8192 holds the ~1378-token prefix plus a
        // 300-word dictation plus the reply with room to spare.
        // WISPR_LLAMA_VERBOSE=1 makes llama.cpp print its backend and layer offload counts: whether
        // the model is on the GPU or silently on the CPU is invisible from latency alone.
        // penaltyRepeat defaults to 1.1, which punishes echoing recent tokens — backwards for
        // cleanup, where a faithful answer repeats most of the transcript. Benched 1.0 vs 1.1 on
        // both quants: no measurable difference, kept neutral because the task copies text.
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

    // One completion. `messages` is the same `[[String: String]]` the HTTP path sends, so both
    // transports run byte-identical prompts and comparing them is honest.
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
                // ~1.7k chars.
                if output.count > 16_000 { break }
            }
        case .mlx(let client):
            // Metal asserts, and aborts the app, when a generation is cancelled mid command-buffer
            // commit, so a deadline miss must never cancel MLX. The stream is drained in a detached
            // task outer cancellation cannot reach; the abandoned generation finishes and is dropped.
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
