import Foundation

struct DictationEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let raw: String
    let cleaned: String
    let appName: String
    let bundleID: String
    let provider: String
    let durationSeconds: Double
}

// JSON-persisted dictation history (most recent first, capped).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let cap = 500

    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BisprBlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    // The two halves of the file format, together so they cannot drift. They did: persist() set
    // .iso8601 while the load used a default decoder (.deferredToDate), so every load threw, `try?`
    // swallowed it, and history silently restarted at zero on every launch — 432 real dictations
    // lost, and nothing said so, because an empty history looks exactly like a new install.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode([DictationEntry].self, from: data) {
            entries = saved
        }
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.cleaned.split(separator: " ").count }
    }

    func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? Self.encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
