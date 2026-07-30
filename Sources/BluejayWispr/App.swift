import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.run()
            return
        }
        // bench/bench.py reads the real prompt from here so it can never drift from the app.
        if CommandLine.arguments.contains("--print-prompt") {
            let messages = LLMCleaner.staticPrefix(vocabulary: AppSettings.shared.vocabulary)
            let json = try! JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted])
            print(String(data: json, encoding: .utf8)!)
            return
        }
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
    private var toast: ToastController!
    private var dashboard: DashboardWindowController!
    private var statusItem: NSStatusItem!
    private var quitMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController()
        dashboard = DashboardWindowController(controller: controller)
        pill = RecordingPillController(controller: controller) { [weak self] section in
            self?.dashboard.show(section)
        }
        toast = ToastController(controller: controller)

        setupMenuBar()
        setupQuitShortcut()
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

        // Left-click opens the app; right-click is the one place Quit lives.
        quitMenu = NSMenu()
        quitMenu.addItem(withTitle: "Quit Bluejay Wispr",
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "Bluejay Wispr — hold fn to dictate, double-tap to lock.\nRight-click to quit."
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = quitMenu          // attached for this click only…
            statusItem.button?.performClick(nil)
            statusItem.menu = nil               // …so a left-click never opens a menu
        } else {
            dashboard.show()
        }
    }

    /// Nothing in the UI offers Quit, but ⌘Q should still work while a window is focused —
    /// an accessory app gets no main menu, and therefore no key equivalent, unless one is set.
    private func setupQuitShortcut() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Bluejay Wispr",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
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
