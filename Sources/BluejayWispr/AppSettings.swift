import Foundation

struct TeamMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var role: String
}

/// UserDefaults-backed settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// Named explicitly, not `.standard`: run as a bare binary (--print-prompt, --self-check)
    /// the process has no bundle id, so `.standard` would be a different domain than the app's
    /// and the benchmark would read a different dictionary than the one in use.
    private let defaults = UserDefaults(suiteName: "ai.getbluejay.wispr") ?? .standard

    enum Provider: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
        case custom = "Custom (OpenAI-compatible)"
        case off = "Off (raw transcript)"
        var id: String { rawValue }
    }

    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    @Published var customEndpoint: String {
        didSet { defaults.set(customEndpoint, forKey: "customEndpoint") }
    }
    @Published var customModel: String {
        didSet { defaults.set(customModel, forKey: "customModel") }
    }
    @Published var customAPIKey: String {
        didSet { defaults.set(customAPIKey, forKey: "customAPIKey") }
    }
    /// Cleanup model id; empty auto-picks from what the provider has loaded.
    @Published var preferredModel: String {
        didSet { defaults.set(preferredModel, forKey: "preferredModel") }
    }
    /// Core Audio UID of the chosen mic; empty follows the system default input.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }
    /// Custom vocabulary — names/jargon the recognizer mishears; injected into cleanup calls.
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
    @Published var launchSoundEnabled: Bool {
        didSet { defaults.set(launchSoundEnabled, forKey: "launchSoundEnabled") }
    }
    /// Which look the app draws in. Every colour and every piece of brand imagery comes from the
    /// matching `Palette`, so this is the only stored piece of a theme.
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Bindings per action, keyed by `ShortcutAction.rawValue` — a String key so the whole
    /// thing is JSON-encodable without a CodingKey dance.
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

    /// Every binding the monitor has to watch for.
    var allBindings: [(ShortcutAction, Shortcut)] {
        ShortcutAction.allCases.flatMap { action in shortcuts(for: action).map { (action, $0) } }
    }

    /// Whether the macOS Globe-key action has to be suppressed while we run.
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

    /// Pure so the self-check can exercise it. Adding a binding *steals* it from every other
    /// action: two actions on one key means only the first one ever fires, silently.
    static func adding(_ shortcut: Shortcut, to action: ShortcutAction,
                       in bindings: [String: [Shortcut]]) -> [String: [Shortcut]] {
        var next = bindings.mapValues { $0.filter { $0 != shortcut } }
        next[action.rawValue, default: []].append(shortcut)
        return next
    }

    /// Display name of the binding that starts a dictation, for user-facing copy.
    var dictationShortcutName: String? {
        (shortcuts(for: .pushToTalk).first
            ?? shortcuts(for: .handsFree).first
            ?? shortcuts(for: .pressEnter).first)?.display
    }

    /// "Hold fn" or "Press ⌥Space" — the verb follows the kind of binding. nil when nothing is
    /// bound to a dictation action at all.
    var holdPhrase: String? {
        dictationShortcutName.map { name in
            shortcuts(for: .pushToTalk).isEmpty ? "Press \(name)" : "Hold \(name)"
        }
    }

    /// "Hold fn to dictate", or a nudge when the user has unbound everything.
    var holdHint: String {
        holdPhrase.map { "\($0) to dictate" } ?? "Set a dictation shortcut in Settings"
    }

    /// Sidebar footer during a hands-free session.
    var lockedHint: String {
        guard let name = dictationShortcutName else { return "Locked. Click the pill to finish" }
        return "Locked. Tap \(name) to finish"
    }

    /// Terms the cleanup model should correct toward: dictionary + team member names.
    /// Always applied — an empty dictionary already means no biasing, so a switch to turn it off
    /// only ever disables words the user deliberately added.
    var vocabulary: [String] {
        var seen = Set<String>()
        return (dictionary + teamMembers.map(\.name))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func addDictionaryWords(_ words: [String]) {
        let existing = Set(dictionary.map { $0.lowercased() })
        let fresh = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !existing.contains($0.lowercased()) }
        var seen = Set<String>()
        dictionary.append(contentsOf: fresh.filter { seen.insert($0.lowercased()).inserted })
    }

    private init() {
        provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .auto
        customEndpoint = defaults.string(forKey: "customEndpoint") ?? ""
        customModel = defaults.string(forKey: "customModel") ?? ""
        customAPIKey = defaults.string(forKey: "customAPIKey") ?? ""
        preferredModel = defaults.string(forKey: "preferredModel") ?? ""
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        dictionary = defaults.stringArray(forKey: "dictionary") ?? ["Bluejay"]
        if let data = defaults.data(forKey: "teamMembers"),
           let saved = try? JSONDecoder().decode([TeamMember].self, from: data) {
            teamMembers = saved
        } else {
            teamMembers = []
        }
        launchSoundEnabled = defaults.object(forKey: "launchSoundEnabled") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .bluejay
        if let data = defaults.data(forKey: "bindings"),
           let saved = try? JSONDecoder().decode([String: [Shortcut]].self, from: data) {
            bindings = saved
        } else {
            bindings = ShortcutAction.allCases.reduce(into: [:]) { $0[$1.rawValue] = $1.defaults }
        }
    }
}
