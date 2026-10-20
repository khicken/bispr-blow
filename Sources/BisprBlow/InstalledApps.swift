import Foundation

struct InstalledApp: Codable, Sendable, Equatable {
    let name: String
    let bundleID: String
    let path: String
}

// Every app "open X" can reach, running or not. Scanned once and refreshed in the background, so a
// command never waits on the disk after the first read.
enum InstalledApps {
    static let rescanAfter: TimeInterval = 600
    static let searchDirectories = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [InstalledApp]?
    nonisolated(unsafe) private static var scannedAt = Date.distantPast
    nonisolated(unsafe) private static var isRescanning = false

    static func all() -> [InstalledApp] {
        lock.lock()
        defer { lock.unlock() }
        guard let apps = cached else {
            let apps = scan()
            store(apps)
            return apps
        }
        if Date().timeIntervalSince(scannedAt) > rescanAfter, !isRescanning {
            isRescanning = true
            DispatchQueue.global(qos: .utility).async {
                let fresh = scan()
                lock.lock()
                store(fresh)
                isRescanning = false
                lock.unlock()
            }
        }
        return apps
    }

    private static func store(_ apps: [InstalledApp]) {
        cached = apps
        scannedAt = Date()
    }

    private static func scan() -> [InstalledApp] {
        searchDirectories.flatMap { directory -> [InstalledApp] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.filter { $0.hasSuffix(".app") }.compactMap { app(at: directory + "/" + $0) }
        }
    }

    private static func app(at path: String) -> InstalledApp? {
        guard let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier else { return nil }
        return InstalledApp(name: withoutAppSuffix(FileManager.default.displayName(atPath: path)), bundleID: bundleID, path: path)
    }

    private static func withoutAppSuffix(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(".app".count)) : name
    }

    // Names are Jev's option keys, so they must be unique; the first directory scanned wins.
    static func choices(_ apps: [InstalledApp], excluding frontBundleID: String?) -> [InstalledApp] {
        var seen = Set<String>()
        let unique = apps.filter { $0.bundleID != frontBundleID && seen.insert($0.name).inserted }
        return Array(unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(Jev.maxChoices))
    }

    static func named(_ spoken: String, in apps: [InstalledApp]) -> InstalledApp? {
        let wanted = comparable(spoken)
        guard !wanted.isEmpty else { return nil }
        return apps.first { comparable($0.name) == wanted }
    }

    private static func comparable(_ name: String) -> String {
        let plain = JayDecide.normalized(withoutAppSuffix(name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))))
        return plain.hasPrefix("the ") ? String(plain.dropFirst("the ".count)) : plain
    }
}
