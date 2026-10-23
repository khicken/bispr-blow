import Foundation
import LocalLLMClient
import LocalLLMClientMLX

// In-process inference. The only file that imports the inference library — everything else reaches
// it through `LLMCleaner.Endpoint`, so changing runtime touches this file and the endpoint list. It
// exists because LM Studio was a dependency the app cannot satisfy on the user's behalf: without it
// every dictation degrades to unpunctuated `ruleClean`. `client` keeps the model resident between
// dictations and frees it after `idleUnload`.
actor LocalEngine {
    static let shared = LocalEngine()

    private var client: MLXClient?
    private var loadedID: String?
    // The launch warm-up and a first dictation can both ask for a load; they share this one.
    private var loading: (id: String, task: Task<MLXClient, Error>)?
    // The generation in flight. A deadline miss leaves it running, so the next completion waits for
    // it rather than starting a second stream on the same client and KV cache.
    private var generation: Task<String, Error>?
    // The model is freed after this long without a completion: the 1.7B one is 1.8 GB held for a
    // whole session otherwise. `LLMCleaner.prepare` loads it again when the shortcut is pressed.
    private static let idleUnload: Duration = .seconds(600)
    private var unload: Task<Void, Never>?

    var loadedModel: String? { client == nil ? nil : loadedID }

    // A dictation is starting on the loaded model, so its idle clock starts over.
    func keepLoaded() {
        if client != nil { scheduleUnload() }
    }

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

    // Every model on disk, as (id, directory). The id is the directory name, so
    // `smallFamilies` / `carefulFamilies` matching works on it unchanged and Fast/Accurate needs no
    // knowledge that the transport changed.
    static func installedModels() -> [(id: String, url: URL)] {
        guard mlxAvailable else { return [] }
        let fm = FileManager.default
        var models: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for root in Self.searchRoots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
                      let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
                      files.contains(where: { $0.pathExtension == "safetensors" })
                else { continue }
                walker.skipDescendants()
                if seen.insert(url.lastPathComponent.lowercased()).inserted {
                    models.append((id: url.lastPathComponent, url: url))
                }
            }
        }
        return models
    }

    // Loads the model if it is not resident.
    private func load(id: String) async throws {
        if loadedID == id, client != nil { return }
        if let pending = loading, pending.id == id {
            client = try await pending.task.value
            loadedID = id
            return
        }
        guard let model = Self.installedModels().first(where: { $0.id == id }) else {
            throw Failure.notInstalled(id)
        }
        let started = Date()
        let task = Task {
            try await LocalLLMClient.mlx(url: model.url,
                                         parameter: .init(maxTokens: 2048, temperature: 0.2))
        }
        loading = (id, task)
        defer { if loading?.id == id { loading = nil } }
        client = try await task.value
        loadedID = id
        logLine("local model loaded \(id) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    // One completion. `messages` is the same `[[String: String]]` the HTTP path sends, so both
    // transports run byte-identical prompts and comparing them is honest.
    func complete(id: String, messages: [[String: String]]) async throws -> String {
        unload?.cancel()
        defer { scheduleUnload() }
        // Looped: while `load` waits, another completion can start a generation or swap the model.
        repeat {
            await finishGeneration()
            try await load(id: id)
        } while generation != nil || loadedID != id
        // A caller whose deadline passed while it waited gets rules; its generation would be dropped.
        try Task.checkCancellation()
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
        // Metal asserts, and aborts the app, when a generation is cancelled mid command-buffer
        // commit, so a deadline miss must never cancel MLX. The stream is drained in a detached
        // task outer cancellation cannot reach; the abandoned generation finishes and is dropped.
        // Drained to the end, never left early: dropping the stream cancels the generation, which is
        // the abort above. `maxTokens` at load is what bounds a model that starts looping.
        let task = Task.detached {
            let stream = try await client.textStream(from: .chat(chat))
            var out = ""
            for await chunk in stream { out += chunk }
            return out
        }
        generation = task
        defer { if generation == task { generation = nil } }
        let output = try await task.value
        logLine("local completion \(Int(Date().timeIntervalSince(started) * 1000))ms \(output.count)chars")
        return output
    }

    private func scheduleUnload() {
        unload?.cancel()
        unload = Task {
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled, generation == nil, loading == nil, let id = loadedID else { return }
            client = nil
            loadedID = nil
            logLine("local model unloaded \(id) after idle")
        }
    }

    private func finishGeneration() async {
        while let pending = generation {
            logLine("local completion waiting on the previous generation")
            _ = try? await pending.value
            if generation == pending { generation = nil }
        }
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
