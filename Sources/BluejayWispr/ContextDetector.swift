import AppKit
import ApplicationServices

struct AppContext {
    let bundleID: String
    let appName: String
    let windowTitle: String
    /// Text already sitting in the field being dictated into. Steers both the recognizer and
    /// cleanup toward the topic and register the user is mid-way through.
    var draft: String = ""
    /// What the field calls itself — a placeholder, label or description, like "Message #general"
    /// or "Search". One phrase, and often the only thing a field exposes when it is still empty,
    /// which is exactly when `draft` has nothing to give.
    var fieldLabel: String = ""

    enum Category: String {
        case messaging, coding, writing, browser, general
    }

    var category: Category {
        let id = bundleID.lowercased()
        let title = windowTitle.lowercased()

        let messaging = ["com.apple.mobilesms", "com.tinyspeck.slackmacgap", "com.hnc.discord",
                         "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "com.facebook.archon"]
        if messaging.contains(where: { id.contains($0) }) { return .messaging }

        let coding = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp",
                      "com.mitchellh.ghostty", "com.microsoft.vscode", "com.todesktop", // Cursor
                      "com.apple.dt.xcode", "com.jetbrains", "dev.zed.zed", "com.sublimetext"]
        if coding.contains(where: { id.contains($0) }) { return .coding }
        if title.contains("claude code") || title.contains("claude") && id.contains("terminal") { return .coding }

        let writing = ["com.apple.mail", "com.microsoft.outlook", "com.apple.iwork.pages",
                       "notion.id", "com.apple.notes", "md.obsidian"]
        if writing.contains(where: { id.contains($0) }) { return .writing }

        let browsers = ["com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
                        "org.mozilla.firefox", "com.brave.browser", "company.thebrowser.dia"]
        if browsers.contains(where: { id.contains($0) }) { return .browser }

        return .general
    }
}

enum ContextDetector {
    /// Snapshot of the frontmost app. Capture at recording start — the recording pill is
    /// non-activating, so the target app stays frontmost.
    static func current() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return AppContext(bundleID: "", appName: "", windowTitle: "")
        }
        let title = focusedWindowTitle(pid: app.processIdentifier) ?? ""
        let field = focusedField(pid: app.processIdentifier)
        return AppContext(
            bundleID: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "",
            windowTitle: title,
            draft: field?.text ?? "",
            fieldLabel: field?.label ?? ""
        )
    }

    /// The focused element, for anyone who needs to come back to it — the correction watcher reads
    /// the same element after the text lands. nil rather than a guess when Accessibility is not
    /// trusted, since every AX call then returns an error rather than a value.
    static func focusedElement() -> (element: AXUIElement, pid: pid_t)? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return focused(pid: pid).map { ($0, pid) }
    }

    private static func focused(pid: pid_t) -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// Whole value of the focused text element, plus what the field calls itself.
    ///
    /// Every read here is on the path that opens the microphone, which is already 150ms of the
    /// user's silence (CLAUDE.md), so the whole thing is bounded: an app that is slow to answer AX
    /// gives back whatever arrived before the budget ran out rather than delaying the mic.
    static func focusedText(element: AXUIElement, limit: Int = 4000) -> String? {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if value as? String == "AXSecureTextField" { return nil }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        // Tail rather than head: the words nearest the cursor are the ones being written about.
        return text.count <= limit ? text : String(text.suffix(limit))
    }

    /// The focused field's text and its own name. Never reads a secure field: a password must not
    /// reach a prompt, a log, or history.
    ///
    /// Selected text is folded in because a selection is the user pointing at the words they mean —
    /// and in an editor it is usually the identifier they are about to dictate about. It leads for
    /// that reason.
    private static func focusedField(pid: pid_t) -> (text: String, label: String)? {
        let deadline = Date().addingTimeInterval(0.12)
        guard let element = focused(pid: pid) else { return nil }
        guard let text = focusedText(element: element) else { return nil }

        var selection = ""
        if Date() < deadline {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &value) == .success,
                let selected = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                selected.count > 1, selected.count <= 200 {
                selection = selected
            }
        }

        var label = ""
        if Date() < deadline {
            for attribute in [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                      let phrase = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !phrase.isEmpty, phrase.count <= 120
                else { continue }
                label = phrase
                break
            }
        }
        return (selection.isEmpty ? text : selection + " " + text, label)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}

extension AppContext {
    /// The words already on screen, handed to the recognizer as bias.
    ///
    /// This is the general mechanism behind mishearing. The recognizer picks between near
    /// homophones using acoustics plus a general-English language model, and general English has
    /// no idea the user is looking at code: "query" comes back as "quarry", "prod" as "proud".
    /// What actually settles it is that the right word is usually already in the buffer being
    /// dictated into, so the fix is to bias toward the buffer rather than to enumerate pairs.
    ///
    /// Identifiers lead, because they are what `contextualStrings` exists for and what no general
    /// model has seen. Plain words follow: in a code buffer or a spec the plain lowercase words
    /// *are* the domain vocabulary, which is what the previous "distinctive shapes only" filter
    /// threw away — `getQuery` biased the recognizer and a buffer full of `query` did not. Only
    /// words that are common in any English are dropped, since biasing "the" biases nothing. The
    /// list stays capped: a long one dilutes every entry in it.
    var draftTerms: [String] {
        var seen = Set<String>()
        var identifiers: [String] = []
        var plain: [String] = []
        for token in (fieldLabel + " " + draft).split(whereSeparator: { $0.isWhitespace }) {
            let term = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}"))
            guard term.count >= 3, term.count <= 30,
                  term.contains(where: \.isLetter),
                  seen.insert(term.lowercased()).inserted
            else { continue }
            if term.dropFirst().contains(where: \.isUppercase)
                || term.contains(".") || term.contains("_") || term.contains("-") {
                identifiers.append(term)
            } else if term.count >= 4, !Self.commonWords.contains(term.lowercased()) {
                plain.append(term)
            }
        }
        let head = Array(identifiers.prefix(Self.termCap))
        return head + plain.prefix(Self.termCap - head.count)
    }

    private static let termCap = 50

    /// Words that are common in every kind of English, so biasing toward them says nothing about
    /// the topic. Deliberately only function words and generic verbs: "cache", "query", "branch",
    /// "commit", "state" and their kind are ordinary English *and* domain terms, and dropping them
    /// would remove exactly the words this is for.
    static let commonWords: Set<String> = [
        "about", "after", "again", "against", "actually", "all", "also", "always", "and", "another",
        "any", "anything", "are", "around", "back", "because", "been", "before", "being", "both",
        "but", "came", "can", "come", "could", "did", "does", "doing", "done", "down", "each",
        "even", "ever", "every", "few", "first", "for", "from", "get", "gets", "getting", "give",
        "going", "gone", "good", "got", "had", "has", "have", "having", "her", "here", "him", "his",
        "how", "into", "its", "itself", "just", "keep", "kind", "know", "last", "least", "less",
        "let", "like", "little", "long", "look", "lot", "made", "make", "makes", "many", "may",
        "maybe", "might", "more", "most", "much", "must", "need", "never", "next", "not", "nothing",
        "now", "off", "once", "one", "only", "onto", "other", "our", "out", "over", "own", "part",
        "put", "quite", "rather", "really", "right", "said", "same", "say", "see", "seen", "shall",
        "she", "should", "since", "some", "something", "still", "such", "sure", "take", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "though", "through", "time", "too", "took", "two", "under",
        "until", "use", "used", "using", "very", "want", "was", "way", "well", "went", "were",
        "what", "when", "where", "whether", "which", "while", "who", "why", "will", "with",
        "without", "would", "yes", "yet", "you", "your",
    ]
}
