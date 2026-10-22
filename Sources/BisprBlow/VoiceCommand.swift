import AppKit
import ApplicationServices
import Security

// A spoken command acted out on the app in front: Jev (TypeSafe System One) picks which on-screen
// element the command is about, and the element's own kind decides the action — press it, type
// into it, or switch to it. Jev only ever chooses from the list it is given, which is the point:
// it cannot invent a click on something that is not there.
enum VoiceCommand {
    // Below this Jev is guessing; on real screens every wrong pick but one sat under it.
    static let confidentEnough = 0.6
    // TypeSafe rejects a choice question with more options than this.
    static let maxChoices = 255
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let model = "jev-1.13.0"
    private static let keychainService = "typesafe-api-key"

    struct Pick {
        let element: ScreenElement
        let confidence: Double
    }

    enum Failure: Error {
        case noKey, keyRejected, badReply
    }

    // Screen text is not the user: a page or a message can show a "Delete account" button. A press
    // that would be hard to take back is asked about, however sure Jev is.
    private static let riskyWords = ["delete", "remove", "send", "pay", "purchase", "buy", "transfer", "submit",
                                     "archive", "discard", "quit", "sign out", "log out", "close account", "merge"]

    static func needsConfirmation(_ element: ScreenElement) -> Bool {
        let label = element.label.lowercased()
        return element.kind == .press && riskyWords.contains { label.contains($0) }
    }

    static func pick(_ spoken: String, among elements: [ScreenElement], appName: String) async throws -> Pick {
        guard let key = apiKey() else { throw Failure.noKey }
        let byLabel = Dictionary(elements.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let body: [String: Any] = [
            "model": model,
            "state": "The user is in \(appName) on a Mac and said: \"\(spoken)\". The choices are the elements on screen, the app's menu items, and the other open apps.",
            "questions": ["target": [
                "type": "choice",
                "instructions": "Which on-screen element, menu item, or other app should be acted on to carry out the command?",
                "criteria": Dictionary(uniqueKeysWithValues: elements.map { ($0.label, NSNull()) }),
            ]],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if [401, 403].contains((response as? HTTPURLResponse)?.statusCode) { throw Failure.keyRejected }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = (reply["answers"] as? [String: Any])?["target"] as? [String: Any],
              let choice = target["choice"] as? String, let element = byLabel[choice],
              let confidence = target["confidence"] as? Double
        else { throw Failure.badReply }
        return Pick(element: element, confidence: confidence)
    }

    // "open Slack" needs no model: a running app named in the command is the whole answer.
    static func appNamed(in spoken: String, among elements: [ScreenElement]) -> ScreenElement? {
        let words = spoken.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard let rest = ["open ", "switch to ", "go to "].lazy.compactMap({ words.hasPrefix($0) ? String(words.dropFirst($0.count)) : nil }).first
        else { return nil }
        return elements.first { $0.kind == .app && $0.app?.localizedName?.lowercased() == rest }
    }

    @MainActor
    static func perform(_ element: ScreenElement, spoken: String) -> Bool {
        switch element.kind {
        case .app:
            return element.app?.activate() ?? false
        case .press:
            guard let node = element.element else { return false }
            return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
        case .field:
            guard let node = element.element,
                  AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            else { return false }
            guard let text = textToType(in: spoken) else { return true }
            // Setting focus can report success without moving it, and the paste goes wherever focus is.
            guard let focused = ContextDetector.focusedElement()?.element, CFEqual(focused, node) else { return false }
            return TextInserter.insert(text)
        }
    }

    // The words to put in a field: everything after "type", "write" or "search for". A command that
    // only names the field ("click into the message box") focuses it and types nothing.
    static func textToType(in spoken: String) -> String? {
        guard let match = typedText.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)),
              let text = Range(match.range(at: 1), in: spoken)
        else { return nil }
        return String(spoken[text])
    }

    private static let typedText = try! NSRegularExpression(
        pattern: #"^\s*(?:type|write|search(?:\s+\w+)?\s+for)\s+(.+?)[.!]?\s*$"#, options: .caseInsensitive)

    // Set with `security add-generic-password -a "$USER" -s typesafe-api-key -w`; never in defaults
    // or the repo, and never logged.
    static func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
