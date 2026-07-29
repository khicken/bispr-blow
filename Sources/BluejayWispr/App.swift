import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar app, no Dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController!
    private var pill: RecordingPillController!
    private var dashboard: DashboardWindowController!
    private var statusItem: NSStatusItem!
    private var quitMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController()
        dashboard = DashboardWindowController(controller: controller)
        pill = RecordingPillController(controller: controller) { [weak self] in
            self?.dashboard.show()
        }

        setupMenuBar()
        DictationController.requestPermissions()
        controller.start()
        SystemFnKey.suppressWhileRunning()

        // First run: open the dashboard so permissions/setup are visible.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            dashboard.show()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let logo = Theme.logo("Symbol_Black") {
                logo.size = NSSize(width: 18, height: 18)
                logo.isTemplate = true  // adapts to menu bar light/dark
                button.image = logo
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Bluejay Wispr")
            }
        }

        // Left-click opens the app directly; right-click is the only place a menu appears
        // (an accessory app has no main menu, so this is the sole route to Quit).
        quitMenu = NSMenu()
        quitMenu.addItem(withTitle: "Quit Bluejay Wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "Bluejay Wispr — hold fn to dictate, double-tap to lock"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = quitMenu           // attach only for this click…
            statusItem.button?.performClick(nil)
            statusItem.menu = nil                // …so left-clicks stay menu-free
        } else {
            dashboard.show()
        }
    }

    /// `open BluejayWispr.app` while running (or Dock/Launchpad click) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemFnKey.restore()
    }
}
