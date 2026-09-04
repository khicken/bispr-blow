import Combine
import Foundation

// Pushes dictation stats — and, under its own opt-in, their text — to the signed-in account, after
// the fact. Local history is the source of truth: this only reads it, and every push is an upsert
// keyed on the entry's UUID, so retries are free and nothing can duplicate. It wakes when history
// gains an entry (debounced, clear of the release-to-paste path) and on a slow timer for whatever a
// failed push left behind. Nothing touches the network unless signed in with the stats toggle on.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    // Which entries have already landed, in its own file next to history.json rather than inside the
    // entries, so `DictationEntry` stays byte-compatible with every history file on disk. Two sets,
    // because text sync can be switched on after years of metric sync.
    struct State: Codable {
        var metrics: Set<UUID> = []
        var texts: Set<UUID> = []

        init() {}

        // Tolerant of missing keys so an older (or newer) file never resets the sets.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metrics = try container.decodeIfPresent(Set<UUID>.self, forKey: .metrics) ?? []
            texts = try container.decodeIfPresent(Set<UUID>.self, forKey: .texts) ?? []
        }
    }

    private let fileURL: URL
    private var state: State
    private var watchers: [AnyCancellable] = []
    private var timer: Timer?
    private var syncing = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BisprBlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sync-state.json")
        fileURL = url
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    // Wiring only — no network happens here, just subscriptions and a timer.
    func start() {
        HistoryStore.shared.$entries
            .dropFirst()
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.kick() }
            .store(in: &watchers)
        // Turning a toggle on is the moment the user expects the backlog to move. The initial
        // published value also lands here, which is what pushes anything dictated while offline.
        AppSettings.shared.$syncStats
            .merge(with: AppSettings.shared.$syncTexts)
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.kick() }
            .store(in: &watchers)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
    }

    // Sync if there is anything to do and the user asked for it; otherwise free.
    func kick() {
        guard !syncing, CloudConfig.ready,
              AppSettings.shared.syncStats,
              CloudClient.shared.session != nil else { return }
        syncing = true
        Task { @MainActor in
            await self.push()
            self.syncing = false
        }
    }

    // Joining a team is the leaderboard opt-in, so rows pushed before the join get restamped
    // with the org — same ids, so this is an update everywhere, never a duplicate.
    func noteOrgChanged() {
        state.metrics = []
        save()
        kick()
    }

    // Sign-out forgets what was synced. The rows themselves are never touched from here — the
    // worst a stale set could do is make the next account's first sync fail, so it goes.
    func reset() {
        state = State()
        save()
    }

    // MARK: - The push

    private func push() async {
        let cloud = CloudClient.shared
        guard let session = cloud.session else { return }
        // The org stamps every row; a member who signed in on a second machine has one on the
        // server that this client has never seen.
        if cloud.org == nil { await cloud.refreshOrg() }

        let entries = HistoryStore.shared.entries
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            for chunk in Self.pending(entries.map(\.id), synced: state.metrics).chunks(of: 100) {
                try await cloud.upsertDictations(chunk.compactMap { byID[$0] }.map {
                    Self.metricRow($0, userID: session.userID, orgID: cloud.org?.id)
                })
                state.metrics.formUnion(chunk)
                save()
            }
            if AppSettings.shared.syncTexts {
                // Texts reference metric rows, so only ids that have landed qualify.
                let eligible = entries.map(\.id).filter { state.metrics.contains($0) }
                for chunk in Self.pending(eligible, synced: state.texts).chunks(of: 100) {
                    try await cloud.upsertTexts(chunk.compactMap { byID[$0] }.map(Self.textRow))
                    state.texts.formUnion(chunk)
                    save()
                }
            }
        } catch {
            // Logged, not shown: the next wake retries from exactly where this stopped.
            logLine("sync push failed: \(error.localizedDescription)")
        }
    }

    // Entries not yet synced, in history order. Pure so the self-check can exercise it.
    nonisolated static func pending(_ ids: [UUID], synced: Set<UUID>) -> [UUID] {
        ids.filter { !synced.contains($0) }
    }

    // One `dictations` row: the schema's metric columns and nothing else — the words themselves
    // never travel on this path.
    nonisolated static func metricRow(_ entry: DictationEntry, userID: UUID, orgID: UUID?) -> [String: Any] {
        var row: [String: Any] = [
            "id": entry.id.uuidString,
            "user_id": userID.uuidString,
            "created_at": CloudClient.iso.string(from: entry.date),
            "word_count": entry.cleaned.split(separator: " ").count,
            "duration_seconds": entry.durationSeconds,
            "app_name": entry.appName,
            "bundle_id": entry.bundleID,
            "provider": entry.provider,
        ]
        if let orgID { row["org_id"] = orgID.uuidString }
        return row
    }

    nonisolated static func textRow(_ entry: DictationEntry) -> [String: Any] {
        ["dictation_id": entry.id.uuidString, "raw": entry.raw, "cleaned": entry.cleaned]
    }

    private func save() {
        // Ids that fell off history's cap can never be re-pushed, so remembering them is bloat.
        let keep = Set(HistoryStore.shared.entries.map(\.id))
        state.metrics.formIntersection(keep)
        state.texts.formIntersection(keep)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
