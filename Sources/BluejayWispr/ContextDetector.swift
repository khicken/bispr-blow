import AppKit
import ApplicationServices

struct AppContext {
    let bundleID: String
    let appName: String
    let windowTitle: String
    /// Text already sitting in the field being dictated into. Steers both the recognizer and
    /// cleanup toward the topic and register the user is mid-way through.
    var draft: String = ""

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
        return AppContext(
            bundleID: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "",
            windowTitle: title,
            draft: focusedText(pid: app.processIdentifier) ?? ""
        )
    }

    /// Contents of the focused text field, tail-truncated. Never reads a secure field: a
    /// password must not reach a prompt, a log, or history.
    private static func focusedText(pid: pid_t, limit: Int = 600) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

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
        return text.count <= limit ? text : String(text.suffix(limit))
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
    /// Names and identifiers from the draft, which are the words a recognizer mishears.
    /// Plain lowercase prose is skipped: it adds noise without biasing anything useful.
    var draftTerms: [String] {
        var seen = Set<String>()
        let terms: [String] = draft
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}")) }
            .filter { term in
                guard term.count >= 3, term.count <= 30 else { return false }
                let distinctive = term.dropFirst().contains(where: \.isUppercase)
                    || term.contains(".") || term.contains("_") || term.contains("-")
                return distinctive && seen.insert(term.lowercased()).inserted
            }
        return Array(terms.prefix(40))
    }
}
