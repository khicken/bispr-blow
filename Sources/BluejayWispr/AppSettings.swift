import Foundation

struct TeamMember: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var role: String
}

/// UserDefaults-backed settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

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
    /// Core Audio UID of the chosen mic; empty follows the system default input.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }
    /// Custom vocabulary — names/jargon the recognizer mishears; injected into cleanup calls.
    @Published var dictionary: [String] {
        didSet { defaults.set(dictionary, forKey: "dictionary") }
    }
    /// Whether dictionary + team names are injected into the LLM cleanup prompt.
    @Published var injectDictionary: Bool {
        didSet { defaults.set(injectDictionary, forKey: "injectDictionary") }
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

    /// Terms the cleanup model should correct toward: dictionary + team member names.
    var vocabulary: [String] {
        guard injectDictionary else { return [] }
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
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        dictionary = defaults.stringArray(forKey: "dictionary") ?? ["Bluejay"]
        injectDictionary = defaults.object(forKey: "injectDictionary") as? Bool ?? true
        if let data = defaults.data(forKey: "teamMembers"),
           let saved = try? JSONDecoder().decode([TeamMember].self, from: data) {
            teamMembers = saved
        } else {
            teamMembers = []
        }
        launchSoundEnabled = defaults.object(forKey: "launchSoundEnabled") as? Bool ?? true
    }
}
