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
        // Dictionary words this Mac has put on the server, spelled exactly as sent.
        var words: Set<String> = []

        init() {}

        // Tolerant of missing keys so an older (or newer) file never resets the sets.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metrics = try container.decodeIfPresent(Set<UUID>.self, forKey: .metrics) ?? []
            texts = try container.decodeIfPresent(Set<UUID>.self, forKey: .texts) ?? []
            words = try container.decodeIfPresent(Set<String>.self, forKey: .words) ?? []
        }
    }

    private let fileURL: URL
    private var state: State
    private var watchers: [AnyCancellable] = []
    private var timer: Timer?
    private var syncing = false
    // Bumped whenever what a landed row means changes (org joined, sign-out). A push that started
    // under an older value must not record its rows as synced: they carry the old org_id.
    private var generation = 0
    private var rerun = false
    private var syncingWords = false
    private var rerunWords = false

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
        // The dictionary goes to teammates as you edit it, so a burst of typing is one push.
        AppSettings.shared.$dictionary
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.kickWords() }
            .store(in: &watchers)
        // Sign-in lands here too: it fetches the org straight afterwards.
        CloudClient.shared.$org
            .map(\.?.id)
            .removeDuplicates()
            .filter { $0 != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.kickWords() }
            .store(in: &watchers)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.kick()
                self?.kickWords()
            }
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
            if self.rerun {
                self.rerun = false
                self.kick()
            }
        }
    }

    // Joining a team is the leaderboard opt-in, so rows pushed before the join get restamped
    // with the org — same ids, so this is an update everywhere, never a duplicate.
    // A push already in flight is told to drop its result and a fresh one follows it.
    func noteOrgChanged() {
        generation += 1
        state.metrics = []
        state.words = []
        save()
        if syncing { rerun = true }
        kick()
        kickWords()
    }

    // Sign-out forgets what was synced. The rows themselves are never touched from here — the
    // worst a stale set could do is make the next account's first sync fail, so it goes.
    func reset() {
        generation += 1
        state = State()
        save()
    }

    // MARK: - The dictionary

    // Mirrors the local dictionary to the server for teammates to read. Only while signed in and in
    // a team; with nothing changed since the last push it never touches the network.
    func kickWords() {
        guard CloudConfig.ready, CloudClient.shared.session != nil else { return }
        if syncingWords {
            rerunWords = true
            return
        }
        syncingWords = true
        Task { @MainActor in
            await self.pushWords()
            self.syncingWords = false
            if self.rerunWords {
                self.rerunWords = false
                self.kickWords()
            }
        }
    }

    private func pushWords() async {
        let cloud = CloudClient.shared
        let local = DictionaryWords.clean(AppSettings.shared.dictionary)
        let plan = DictionaryWords.plan(local: local, synced: state.words)
        guard !plan.upsert.isEmpty || !plan.delete.isEmpty else { return }
        if cloud.org == nil { await cloud.refreshOrg() }
        guard cloud.org != nil else { return }

        let started = generation
        do {
            // Deletes first: a recased word is a delete of the old spelling and an upsert of the
            // new one, and in that order a case-insensitive key still ends up with the new one.
            for chunk in plan.delete.chunks(of: 25) { try await cloud.deleteDictionaryWords(chunk) }
            for chunk in plan.upsert.chunks(of: 100) { try await cloud.upsertDictionaryWords(chunk) }
            guard started == generation else { return }
            state.words = Set(local)
            save()
        } catch {
            logLine("dictionary sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - The push

    private func push() async {
        let cloud = CloudClient.shared
        guard let session = cloud.session else { return }
        // The org stamps every row; a member who signed in on a second machine has one on the
        // server that this client has never seen.
        if cloud.org == nil { await cloud.refreshOrg() }

        let started = generation
        let entries = HistoryStore.shared.entries
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            for chunk in Self.pending(entries.map(\.id), synced: state.metrics).chunks(of: 100) {
                let landed = try await deliver(chunk, rows: {
                    byID[$0].map { Self.metricRow($0, userID: session.userID, orgID: cloud.org?.id) }
                }, post: cloud.upsertDictations)
                // The org changed mid-push: these rows carry the old one, so leave them unrecorded.
                guard started == generation else { return }
                state.metrics.formUnion(landed)
                save()
            }
            if AppSettings.shared.syncTexts {
                // Texts reference metric rows, so only ids that have landed qualify.
                let eligible = entries.map(\.id).filter { state.metrics.contains($0) }
                for chunk in Self.pending(eligible, synced: state.texts).chunks(of: 100) {
                    let landed = try await deliver(chunk, rows: { byID[$0].map(Self.textRow) },
                                                   post: cloud.upsertTexts)
                    guard started == generation else { return }
                    state.texts.formUnion(landed)
                    save()
                }
            }
        } catch {
            // Logged, not shown: the next wake retries from exactly where this stopped.
            logLine("sync push failed: \(error.localizedDescription)")
        }
    }

    // Posts one chunk. One row the server refuses must not hold the queue: on a rejection the chunk
    // is halved until the bad row stands alone, and that row is logged and counted as done so
    // everything behind it moves. Anything else (offline, 5xx, signed out) throws for the retry.
    private func deliver(_ ids: [UUID], rows build: (UUID) -> [String: Any]?,
                         post: ([[String: Any]]) async throws -> Void) async throws -> [UUID] {
        do {
            try await post(ids.compactMap(build))
            return ids
        } catch let error as CloudError where Self.isRowRejection(error.status) {
            guard ids.count > 1 else {
                logLine("sync skipped a row the server rejects (\(error.status ?? 0)): \(ids[0])")
                return ids
            }
            let mid = ids.count / 2
            let head = try await deliver(Array(ids[..<mid]), rows: build, post: post)
            return head + (try await deliver(Array(ids[mid...]), rows: build, post: post))
        }
    }

    // A 4xx that is about the payload. Auth, timeout and rate limits are about the moment, so
    // splitting would only multiply the failures.
    nonisolated static func isRowRejection(_ status: Int?) -> Bool {
        guard let status, (400..<500).contains(status) else { return false }
        return ![401, 403, 408, 429].contains(status)
    }

    // Postgres text cannot hold NUL, and JSON carries it as \u0000, which the server refuses.
    nonisolated static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0000}", with: "")
    }

    // `duration_seconds` is not null and checked >= 0. NaN or infinity would also crash
    // JSONSerialization with an uncatchable exception, so they become 0.
    nonisolated static func finiteDuration(_ seconds: Double) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
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
            "duration_seconds": finiteDuration(entry.durationSeconds),
            "app_name": sanitized(entry.appName),
            "bundle_id": sanitized(entry.bundleID),
            "provider": sanitized(entry.provider),
        ]
        if let orgID { row["org_id"] = orgID.uuidString }
        return row
    }

    nonisolated static func textRow(_ entry: DictationEntry) -> [String: Any] {
        ["dictation_id": entry.id.uuidString, "raw": sanitized(entry.raw),
         "cleaned": sanitized(entry.cleaned)]
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
