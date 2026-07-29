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

/// JSON-persisted dictation history (most recent first, capped).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let cap = 500

    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BluejayWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DictationEntry].self, from: data) {
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
