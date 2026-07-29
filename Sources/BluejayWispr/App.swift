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

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Bluejay Wispr", action: #selector(openDashboard), keyEquivalent: "o")
            .target = self
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Hold fn to dictate · double-tap to lock", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openDashboard() {
        dashboard.show()
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
