import AppKit
import ApplicationServices

struct AppContext {
    let bundleID: String
    let appName: String
    let windowTitle: String

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
            windowTitle: title
        )
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
