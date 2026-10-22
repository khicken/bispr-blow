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
            "state": "The user is in \(appName) on a Mac and said: \"\(spoken)\". The choices are the elements on screen, the app's menu items, the other open apps, and opening a website.",
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
        case .web:
            return webAddress(for: spoken).map { NSWorkspace.shared.open($0) } ?? false
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

    // Where "go to LinkedIn" lands: a spoken domain as itself, "search for X" as a search, and a bare
    // name as DuckDuckGo's first result, which is the site itself for anything with a home page.
    static func webAddress(for spoken: String) -> URL? {
        let phrase = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let isSearch = phrase.range(of: #"^search\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let target = phrase.replacingOccurrences(of: webVerbs, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if !isSearch, target.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://\(target)")
        }
        let query = (isSearch ? target : "\\" + target).addingPercentEncoding(withAllowedCharacters: queryValue) ?? target
        return URL(string: "https://duckduckgo.com/?q=\(query)")
    }

    // `.urlQueryAllowed` keeps & + = and #, which would split or end the query: "C++ & Rust".
    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#;?/"))

    private static let webVerbs = #"^(?:go to|open|visit|pull up|look up|search(?: the web| google| online)?(?: for)?)\s+(?:the\s+)?"#

    // "open Linear and create a new issue" is two commands, each on the screen the last one left.
    // A "type" step keeps the rest of the sentence: "type salt and pepper" is one thing to type.
    static func steps(in spoken: String) -> [String] {
        var steps: [String] = []
        var rest = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        while textToType(in: rest) == nil,
              let joint = chainJoint.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let range = Range(joint.range, in: rest) {
            steps.append(String(rest[..<range.lowerBound]))
            rest = String(rest[range.upperBound...])
        }
        return (steps + [rest]).filter { !$0.isEmpty }
    }

    // A pause mid-command ("go to" … "LinkedIn", "open Slack and" … "go to DMs") is not its end.
    static func isUnfinished(_ said: String) -> Bool {
        let last = said.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(separator: " ").last.map { $0.lowercased() }
        return last.map { danglingWords.contains($0) } ?? false
    }

    static func withoutLeadingJoint(_ said: String) -> String {
        said.replacingOccurrences(of: #"^\s*(?:and\s+then|then|and)\b[\s,]*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let danglingWords: Set<String> = ["and", "then", "to", "for", "the", "a", "my", "go", "open", "type", "write", "search", "into", "on"]

    // Only an "and" or "then" followed by a command verb is a joint; "cats and dogs" is not.
    private static let chainJoint = try! NSRegularExpression(
        pattern: #"\s*,?\s+(?:and\s+then|then|and)\s+(?=(?:open|go|click|press|tap|switch|type|write|search|show|create|start|close|reply|select|check|look|pull|visit|make|add|mark|react|stop)\b)"#,
        options: .caseInsensitive)

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
