import Foundation

struct JayRecipeStep: Codable, Equatable {
    enum Kind: String { case press, type, system, app, url }
    let kind: String
    let target: String
    let text: String?
}

extension JayRecipeStep {
    init(_ kind: Kind, target: String, text: String? = nil) {
        self.init(kind: kind.rawValue, target: target, text: text)
    }
}

struct JayRecipe: Codable, Equatable {
    let key: String
    var steps: [JayRecipeStep]
    var lastUsed: Date
}

// Tasks that finished, kept per app, window and phrase so the same request replays without Jev.
// It holds screen labels and typed text, so it stays a local file and nothing in it is ever logged.
final class JayRecipes: @unchecked Sendable {
    static let shared = JayRecipes(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BisprBlow/jay-recipes.json"))
    static let maxRecipes = 200

    private let fileURL: URL
    private let lock = NSLock()
    private var recipes: [String: JayRecipe]

    init(fileURL: URL) {
        self.fileURL = fileURL
        recipes = Self.readRecipes(from: fileURL)
    }

    static func key(bundleID: String, windowTitle: String, phrase: String) -> String {
        "\(bundleID)|\(windowTitle)|\(JayDecide.normalized(phrase))"
    }

    func recipe(for key: String) -> JayRecipe? { lock.withLock { recipes[key] } }

    func save(_ recipe: JayRecipe) {
        lock.withLock {
            recipes[recipe.key] = recipe
            let overflow = recipes.count - Self.maxRecipes
            if overflow > 0 {
                for stale in recipes.values.sorted(by: { $0.lastUsed < $1.lastUsed }).prefix(overflow) {
                    recipes[stale.key] = nil
                }
            }
            writeRecipes()
        }
    }

    static func step(for action: JayAction) -> JayRecipeStep {
        switch action {
        case .press(let element): return JayRecipeStep(.press, target: element.label)
        // an empty target means whichever field has focus when the step replays
        case .type(let text, let field): return JayRecipeStep(.type, target: field?.label ?? "", text: text)
        case .system(let system): return JayRecipeStep(.system, target: system.id)
        case .openApp(let app): return JayRecipeStep(.app, target: app.bundleID)
        case .openURL(let url): return JayRecipeStep(.url, target: url.absoluteString)
        }
    }

    // The screen check before a replayed step: a press or a typed field needs that exact label on screen now.
    static func action(for step: JayRecipeStep, screen: ScreenSnapshot, apps: [InstalledApp]) -> JayAction? {
        let element = screen.elements.first { $0.label == step.target }
        switch JayRecipeStep.Kind(rawValue: step.kind) {
        case .press: return element.map { .press($0) }
        case .type:
            guard let text = step.text else { return nil }
            if step.target.isEmpty { return .type(text, into: nil) }
            return element.map { .type(text, into: $0) }
        case .system: return SystemAction.named(step.target).map { .system($0) }
        case .app: return apps.first { $0.bundleID == step.target }.map { .openApp($0) }
        case .url: return URL(string: step.target).map { .openURL($0) }
        case nil: return nil
        }
    }

    private static func readRecipes(from fileURL: URL) -> [String: JayRecipe] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let saved = try JSONDecoder().decode([JayRecipe].self, from: Data(contentsOf: fileURL))
            return Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer })
        } catch {
            // --self-check writes a broken file on purpose, so the name tells its line from the real store's
            logLine("jay recipes unreadable file=\(fileURL.lastPathComponent) error=\(error.localizedDescription)")
            return [:]
        }
    }

    private func writeRecipes() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(recipes.values)).write(to: fileURL, options: .atomic)
        } catch {
            logLine("jay recipes unwritable error=\(error.localizedDescription)")
        }
    }
}
