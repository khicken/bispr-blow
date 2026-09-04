import AppKit
import Foundation
import ServiceManagement

struct TeamMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var role: String
}

// UserDefaults-backed settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    // Named explicitly, not `.standard`: run as a bare binary the process has no bundle id, so
    // `.standard` would be a different domain than the app's and the bench would read a different
    // dictionary than the one in use.
    private let defaults = UserDefaults(suiteName: "ai.getbluejay.bisprblow") ?? .standard

    // The only thing the user gets to say about cleanup: how much of the pause after they let go it
    // may spend. Which server is running and which model id it holds are things the app works out.
    enum Cleanup: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case accurate = "Accurate"
        var id: String { rawValue }

        // What you get, on the row next to the name. The names already say which is quicker; what a
        // user cannot guess is which of their dictations each one suits.
        var detail: String {
            switch self {
            case .fast: "Best for a sentence or two"
            case .accurate: "Best for long, rambling dictations"
            }
        }
    }

    @Published var cleanup: Cleanup {
        didSet { defaults.set(cleanup.rawValue, forKey: "cleanup") }
    }
    // Core Audio UID of the chosen mic; empty follows the system default input.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }
    // Custom vocabulary — names/jargon the recognizer mishears; injected into cleanup calls.
    @Published var dictionary: [String] {
        didSet { defaults.set(dictionary, forKey: "dictionary") }
    }
    @Published var teamMembers: [TeamMember] {
        didSet {
            if let data = try? JSONEncoder().encode(teamMembers) {
                defaults.set(data, forKey: "teamMembers")
            }
        }
    }
    // A click when the mic opens and one when the text lands. The only feedback that reaches you
    // while you are looking at the app you are dictating into rather than at the pill.
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "launchSoundEnabled") }
    }
    // Keep the pill on screen while idle. Off, it only appears once you start dictating — the
    // window still opens from the menu bar item, so nothing becomes unreachable.
    @Published var alwaysShowPill: Bool {
        didSet { defaults.set(alwaysShowPill, forKey: "alwaysShowPill") }
    }
    // A Dock icon as well as the menu bar item. Off by default: it is a background app that you
    // drive from a shortcut, and a Dock icon for it is a second way to do nothing.
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }
    // Start with the machine. The real state lives in the login-item registration, so this reads
    // back from `SMAppService` — a user can revoke it in System Settings and never touch us.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            // Throws when there is no bundle to register (the CLI seams), which is exactly the
            // case where a login item means nothing.
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                logLine("login item \(launchAtLogin ? "register" : "unregister") failed: \(error)")
            }
        }
    }
    // Lowercase the first word of every sentence that lands at the cursor. A post-pass rather than a
    // prompt rule, so it holds on the rule-based path and costs nothing on the cached prefix.
    @Published var lowercaseSentences: Bool {
        didSet { defaults.set(lowercaseSentences, forKey: "lowercaseSentences") }
    }
    // Keep the period cleanup puts on the end of a dictation. Off by default: a word or two kept
    // landing as "word.", and the period is the model's habit. A post-pass, like the lowercasing.
    @Published var endWithPeriod: Bool {
        didSet { defaults.set(endWithPeriod, forKey: "endWithPeriod") }
    }
    // Raise the system input volume back to a healthy level before each dictation. Off by
    // default: it writes a system setting, so the user opts in rather than discovers it.
    @Published var restoreMicVolume: Bool {
        didSet { defaults.set(restoreMicVolume, forKey: "restoreMicVolume") }
    }
    // One request to api.github.com at launch, asking whether a newer release is out. On by
    // default: an update nobody hears about is the same as no update, and an opt-in check that
    // nobody finds is dead code. Off, nothing is asked and nothing is sent — and it is the only
    // network call the app makes without being signed in.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    // Which look the app draws in. Every colour, image and type face comes from the matching
    // `Palette`, so this is the only stored piece of a theme.
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            Theme.applyToNativeControls()
        }
    }
    // Whether macOS is in dark mode. Published rather than read from `NSApp` at draw time: `Theme`
    // is a table of statics with no view to observe, and a view only repaints when something it
    // observes changes, so System mode would keep the palette it launched with. `App.swift` keeps
    // this current.
    @Published var systemIsDark: Bool = false
    // Back up dictation stats — counts and timings, never text — to the signed-in account.
    // Off by default: the app's promise is that nothing leaves the machine unless asked.
    @Published var syncStats: Bool {
        didSet { defaults.set(syncStats, forKey: "syncStats") }
    }
    // Also back up what was said, readable only by its author. Its own opt-in, so "my stats but
    // not my words" is a real setting rather than a hope.
    @Published var syncTexts: Bool {
        didSet { defaults.set(syncTexts, forKey: "syncTexts") }
    }
    // An override for the compiled-in Supabase project, read once at launch. Empty is the normal
    // case and means "use the project in `CloudConfig`" — it is not an off switch.
    let cloudURL: String
    let cloudAnonKey: String
    // Bindings per action, keyed by `ShortcutAction.rawValue` — a String key so the whole
    // thing is JSON-encodable without a CodingKey dance.
    @Published var bindings: [String: [Shortcut]] {
        didSet {
            if let data = try? JSONEncoder().encode(bindings) {
                defaults.set(data, forKey: "bindings")
            }
            ShortcutMonitor.shared.reload()
        }
    }

    // MARK: - Shortcuts

    func shortcuts(for action: ShortcutAction) -> [Shortcut] { bindings[action.rawValue] ?? [] }

    // Every binding the monitor has to watch for.
    var allBindings: [(ShortcutAction, Shortcut)] {
        ShortcutAction.allCases.flatMap { action in shortcuts(for: action).map { (action, $0) } }
    }

    // Whether the macOS Globe-key action has to be suppressed while we run.
    var fnIsBound: Bool { allBindings.contains { $0.1.usesFn } }

    func add(_ shortcut: Shortcut, to action: ShortcutAction) {
        bindings = Self.adding(shortcut, to: action, in: bindings)
    }

    func remove(_ shortcut: Shortcut, from action: ShortcutAction) {
        bindings[action.rawValue] = shortcuts(for: action).filter { $0 != shortcut }
    }

    func resetToDefault(_ action: ShortcutAction) {
        var next = bindings.mapValues { $0.filter { !action.defaults.contains($0) } }
        next[action.rawValue] = action.defaults
        bindings = next
    }

    // "Bluejay" and "Bluejay World" were the two themes before there were five. The second was a
    // deliberate pick and is kept as World; the first was the only light option there was, so having
    // it stored says nothing about wanting light and it lands on System. Pure so the self-check can
    // exercise it: get this wrong and every existing install silently loses its theme.
    static func appearance(stored: String?) -> Appearance {
        guard let stored else { return .system }
        return Appearance(rawValue: stored) ?? (stored == "Bluejay World" ? .world : .system)
    }

    // Pure so the self-check can exercise it. Adding a binding *steals* it from every other
    // action: two actions on one key means only the first one ever fires, silently.
    static func adding(_ shortcut: Shortcut, to action: ShortcutAction,
                       in bindings: [String: [Shortcut]]) -> [String: [Shortcut]] {
        var next = bindings.mapValues { $0.filter { $0 != shortcut } }
        next[action.rawValue, default: []].append(shortcut)
        return next
    }

    // Display name of the binding that starts a dictation, for user-facing copy.
    var dictationShortcutName: String? {
        (shortcuts(for: .pushToTalk).first
            ?? shortcuts(for: .handsFree).first
            ?? shortcuts(for: .pressEnter).first)?.display
    }

    // "Hold fn" or "Press ⌥Space" — the verb follows the kind of binding. nil when nothing is
    // bound to a dictation action at all.
    var holdPhrase: String? {
        dictationShortcutName.map { name in
            shortcuts(for: .pushToTalk).isEmpty ? "Press \(name)" : "Hold \(name)"
        }
    }

    // "Hold fn to dictate", or a nudge when the user has unbound everything.
    var holdHint: String {
        holdPhrase.map { "\($0) to dictate" } ?? "Set a dictation shortcut in Settings"
    }

    // Terms the cleanup model should correct toward: dictionary + team member names. Always applied
    // — an empty dictionary already means no biasing.
    var vocabulary: [String] {
        var seen = Set<String>()
        return (dictionary + teamMembers.map(\.name))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func addDictionaryWords(_ words: [String]) {
        var seen = Set(dictionary.map { $0.lowercased() })
        for word in words.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !word.isEmpty {
            // Re-adding a stored word with different casing is the user fixing the casing
            // ("claude" → "Claude"), not a duplicate to drop silently.
            if let existing = dictionary.firstIndex(where: { $0.lowercased() == word.lowercased() }) {
                if dictionary[existing] != word { dictionary[existing] = word }
            } else if seen.insert(word.lowercased()).inserted {
                dictionary.append(word)
            }
        }
    }

    private init() {
        cleanup = Cleanup(rawValue: defaults.string(forKey: "cleanup") ?? "") ?? .fast
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        dictionary = defaults.stringArray(forKey: "dictionary") ?? ["Bluejay"]
        if let data = defaults.data(forKey: "teamMembers"),
           let saved = try? JSONDecoder().decode([TeamMember].self, from: data) {
            teamMembers = saved
        } else {
            teamMembers = []
        }
        soundsEnabled = defaults.object(forKey: "launchSoundEnabled") as? Bool ?? true
        alwaysShowPill = defaults.object(forKey: "alwaysShowPill") as? Bool ?? true
        showInDock = defaults.bool(forKey: "showInDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        syncStats = defaults.bool(forKey: "syncStats")
        syncTexts = defaults.bool(forKey: "syncTexts")
        cloudURL = defaults.string(forKey: "cloudURL") ?? ""
        cloudAnonKey = defaults.string(forKey: "cloudAnonKey") ?? ""
        lowercaseSentences = defaults.bool(forKey: "lowercaseSentences")
        endWithPeriod = defaults.bool(forKey: "endWithPeriod")
        restoreMicVolume = defaults.bool(forKey: "restoreMicVolume")
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        appearance = Self.appearance(stored: defaults.string(forKey: "appearance"))
        if let data = defaults.data(forKey: "bindings"),
           let saved = try? JSONDecoder().decode([String: [Shortcut]].self, from: data) {
            bindings = saved
        } else {
            bindings = ShortcutAction.allCases.reduce(into: [:]) { $0[$1.rawValue] = $1.defaults }
        }
    }
}
