import Foundation

/// Fetches the Accurate weights when the installer's optional payload was skipped.
///
/// Staging is a dot-prefixed directory because `LocalEngine.installedModels` enumerates with
/// `.skipsHiddenFiles`: a partly-written model stays invisible to the scanner, so MLX can never be
/// handed a truncated safetensors — which aborts the process rather than throwing, at the first
/// dictation rather than at download time.
@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    /// The weights `package.sh` installs as "Accurate writing", and the ones bench/results.md was
    /// measured on. Downloading anything else would make the numbers there describe a different app.
    static let repo = "lmstudio-community/Qwen3-1.7B-MLX-8bit"
    static var modelName: String { String(repo.split(separator: "/").last!) }

    @Published private(set) var fraction: Double?
    @Published private(set) var failure: String?

    private var job: Task<Void, Never>?
    var isRunning: Bool { job != nil }

    private var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BluejayWispr/models")
    }

    func start(then finished: @escaping () -> Void) {
        guard job == nil else { return }
        failure = nil
        fraction = 0
        job = Task {
            do {
                try await run()
                job = nil
                fraction = nil
                finished()
            } catch is CancellationError {
                job = nil
                fraction = nil
            } catch {
                failure = error.localizedDescription
                job = nil
                fraction = nil
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        fraction = nil
    }

    private func run() async throws {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".incoming-\(Self.modelName)")
        let installed = root.appendingPathComponent(Self.modelName)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let files = try await listing()
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var carried: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(file.name)")!
            let written = try await Fetch.file(url, to: staging.appendingPathComponent(file.name)) { got in
                Task { @MainActor [weak self] in
                    self?.fraction = Double(carried + got) / Double(max(total, 1))
                }
            }
            // The truncation CLAUDE.md warns is invisible until first dictation, caught here instead.
            guard written == file.size else { throw Failure.short(file.name, written, file.size) }
            carried += written
        }

        try? fm.removeItem(at: installed)
        try fm.moveItem(at: staging, to: installed)
    }

    private struct Remote { let name: String; let size: Int64 }

    private func listing() async throws -> [Remote] {
        let api = URL(string: "https://huggingface.co/api/models/\(Self.repo)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]]
        else { throw Failure.noListing }

        let files = siblings.compactMap { entry -> Remote? in
            guard let name = entry["rfilename"] as? String,
                  let size = entry["size"] as? Int64 ?? (entry["size"] as? Int).map(Int64.init),
                  !name.hasPrefix("."), name != "README.md"
            else { return nil }
            return Remote(name: name, size: size)
        }
        guard files.contains(where: { $0.name == "config.json" }),
              files.contains(where: { $0.name.hasSuffix(".safetensors") })
        else { throw Failure.noListing }
        return files
    }

    enum Failure: LocalizedError {
        case noListing
        case short(String, Int64, Int64)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noListing: return "Could not reach the model download."
            case .short(let name, let got, let want): return "\(name) arrived short (\(got) of \(want) bytes)."
            case .http(let code): return "The download failed (HTTP \(code))."
            }
        }
    }
}

/// One file to one path, reporting bytes as they land. `URLSession`'s async `download` gives no
/// progress on its own, and its `AsyncBytes` only yields one byte at a time, which cannot move 1.8 GB
/// — so a per-task delegate is the way to see inside the transfer.
private enum Fetch {
    static func file(_ url: URL, to path: URL,
                     progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let (temp, response) = try await URLSession.shared.download(
            from: url, delegate: Reporter(progress: progress))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ModelDownloader.Failure.http(code) }
        let fm = FileManager.default
        try? fm.removeItem(at: path)
        try fm.moveItem(at: temp, to: path)
        return (try fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private final class Reporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: @Sendable (Int64) -> Void
        init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        // Required by the protocol; the async `download` moves the file itself.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
