import AppKit
import Foundation

// Asks GitHub once at launch whether a newer release exists, and tells the user. It does not
// install anything, and Sparkle is not the next step until there is a Developer ID: an update
// Sparkle downloaded would be quarantined and unnotarized, so macOS would refuse to launch what it
// had just put in /Applications — strictly worse than not updating at all.
//
// Every failure is silence. Offline is the normal case for this app, and an app whose pitch is that
// nothing leaves your machine cannot answer a dropped connection with an error.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    // Set only while it is genuinely newer than this build, so the banner's existence *is* the
    // answer and no view has to compare anything.
    @Published private(set) var latest: String?

    static let releasePage = URL(string: "https://github.com/khicken/bispr-blow/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/khicken/bispr-blow/releases/latest")!

    // What build.sh stamped from the newest git tag. A bare `swift build` binary has no bundle and
    // so no version, and something with no version is never behind anything.
    static var current: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func check() async {
        guard AppSettings.shared.checkForUpdates, let current = Self.current else { return }
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return }
        guard Self.isNewer(tag, than: current) else { return }
        latest = Self.number(tag)
        logLine("update: \(current) -> \(latest ?? tag) available")
    }

    // Numerically per component, so 0.10.0 beats 0.9.0 — a string compare gets that backwards, and
    // the first release past .9 is exactly when nobody would be looking. Anything unparseable
    // compares as not newer: a tag we do not understand is not worth nagging about.
    // nonisolated: pure, and the self-check calls it from a synchronous context.
    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        let parts: (String) -> [Int]? = { text in
            let fields = number(text).split(separator: ".", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Int($0) }
            return numbers.count == fields.count && !numbers.isEmpty ? numbers : nil
        }
        guard let new = parts(latest), let old = parts(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let (a, b) = (index < new.count ? new[index] : 0, index < old.count ? old[index] : 0)
            if a != b { return a > b }
        }
        return false
    }

    // "v0.2.0" and "0.2.0" are the same release; the tag carries the v and Info.plist cannot.
    nonisolated static func number(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
