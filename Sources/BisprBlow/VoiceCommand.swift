import Foundation

// The text side of a spoken command: splitting chained commands, finding the words to type, the web
// address a "go to" lands on, and which words make an action worth asking about first.
enum VoiceCommand {
    // Screen text is not the user: a page or a message can show a "Delete account" button. An action
    // that would be hard to take back is asked about, however sure Jev is.
    private static let riskyWords = ["delete", "remove", "send", "pay", "purchase", "buy", "transfer", "submit",
                                     "archive", "discard", "quit", "sign out", "log out", "close account", "merge",
                                     "trash", "erase", "empty", "post", "publish", "share", "approve", "uninstall",
                                     "reset", "leave", "decline", "confirm", "order", "checkout", "check out",
                                     "deploy", "reply all", "kill", "close all", "force", "wipe", "revoke", "unsubscribe",
                                     "cancel subscription", "get rid of", "nuke", "close every"]

    // A word prefix, so "sending" and "Move to Trash" count but "resend" does not. "Go forward" is a
    // browser's history, forwarding mail is not. "Clear" needs an object: "Clear History" counts, a
    // calculator's "All Clear (button)" does not.
    private static let riskyWord = try! NSRegularExpression(
        pattern: #"\b(?:"# + riskyWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + #"|(?<!go )(?<!fast )forward|clear\s+\w|bin\b|ship\s+it\b|(?:sign|log)\s+me\s+out)"#,
        options: .caseInsensitive)

    static func hasRiskyWord(_ text: String) -> Bool {
        riskyWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // Where "go to LinkedIn" lands: a spoken domain as itself, "search for X" as a search, and a bare
    // name as DuckDuckGo's first result, which is the site itself for anything with a home page.
    static func webAddress(for spoken: String) -> URL? {
        let phrase = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let isSearch = phrase.range(of: #"^search\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let target = target(of: phrase)
        guard !target.isEmpty else { return nil }
        if !isSearch, target.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://\(target)")
        }
        let query = (isSearch ? target : "\\" + target).addingPercentEncoding(withAllowedCharacters: queryValue) ?? target
        return URL(string: searchPrefix + query)
    }

    // A spoken address with a web suffix ("open railway.app", "go to github.com") is the site itself, so it
    // needs no model; "open notes.txt" is not.
    static func spokenSite(in spoken: String) -> URL? {
        guard let url = webAddress(for: spoken), !url.absoluteString.hasPrefix(searchPrefix),
              let suffix = url.host()?.split(separator: ".").last, webSuffixes.contains(suffix.lowercased())
        else { return nil }
        return url
    }

    // Saying the web, a search engine or a domain anywhere in the command: "look up the weather", "go to github.com".
    static func asksForWeb(_ spoken: String) -> Bool {
        webRequest.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) != nil
    }

    private static let webRequest = try! NSRegularExpression(
        pattern: #"\b(?:web|website|site|online|internet|google|googling|duckduckgo|look\s+up)\b|\b[\w-]+\.(?:"#
            + webSuffixes.sorted().joined(separator: "|") + #")\b"#,
        options: .caseInsensitive)

    private static let searchPrefix = "https://duckduckgo.com/?q="
    private static let webSuffixes: Set<String> = ["com", "org", "net", "io", "ai", "app", "dev", "co", "so", "me", "us", "uk",
                                                   "ca", "de", "fr", "in", "edu", "gov", "xyz", "tv", "gg", "sh", "tech", "page"]

    // `.urlQueryAllowed` keeps & + = and #, which would split or end the query: "C++ & Rust".
    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#;?/"))

    // What a "go to" names: "go to the Bluejay docs" → "Bluejay docs".
    static func target(of spoken: String) -> String {
        spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: webVerbs, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

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

    // Live speech opens with what a typed command never has: "Um, can you go to railway?" is "go to railway".
    static func withoutLeadIn(_ said: String) -> String {
        let command = said.replacingOccurrences(of: leadIn, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[\s,]+please[\s.!?]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "Okay." on its own is still something said, and Jev's to read
        return JayDecide.normalized(command).isEmpty ? said.trimmingCharacters(in: .whitespacesAndNewlines) : command
    }

    private static let leadIn = #"^(?:\s*(?:and\s+then|then|and|u+m+|u+h+|uhm|erm|hmm+|oh|okay|ok|so|alright|all right|hey|please|just|"#
        + #"(?:can|could|would|will)\s+you|go\s+ahead\s+and|i\s+(?:want|need)\s+(?:you\s+)?to|let'?s)\b[\s,.!?]*)+"#

    private static let danglingWords: Set<String> = ["and", "then", "to", "for", "the", "a", "my", "go", "open", "type", "write", "search",
                                                    "into", "on", "with", "in", "at", "from", "called", "named", "saying", "switch"]

    // Only an "and" or "then" followed by a command verb is a joint; "cats and dogs" is not.
    private static let chainJoint = try! NSRegularExpression(
        pattern: #"\s*,?\s+(?:and\s+then|then|and)\s+(?=(?:open|go|click|press|tap|switch|type|write|search|show|create|start|close|reply|select|check|look|pull|visit|make|add|mark|react|stop|run|scroll|sort|change|hit|enter|filter|rename|find|save|copy|paste|move|set|turn|zoom|reload|refresh|play)\b)"#,
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
}
