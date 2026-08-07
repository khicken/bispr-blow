import AppKit
import SwiftUI

/// Runs one async call to completion from a synchronous CLI entry point.
///
/// `Task.detached` and not `Task`: `main()` on a `@main` type is MainActor-isolated, so a plain
/// `Task` inherits that isolation and can only run when the main thread yields — which the
/// semaphore below guarantees it never will. That deadlocks outright rather than running slowly,
/// and it presents as a hung model with no log output at all, which is a bad afternoon.
private final class ResultBox<V>: @unchecked Sendable { var value: V? }

private func awaitSync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await body(); done.signal() }
    done.wait()
    return box.value!
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.run()
            return
        }
        // bench/bench.py reads the real prompts from here so they can never drift from the app.
        // Both variants, keyed the way the bench selects them: {"default": [...], "lowTouch": [...]}.
        if CommandLine.arguments.contains("--print-prompt") {
            let prompts = [
                "default": LLMCleaner.staticPrefix(vocabulary: AppSettings.shared.vocabulary),
                "lowTouch": LLMCleaner.staticPrefix(vocabulary: AppSettings.shared.vocabulary,
                                                    lowTouch: true),
            ]
            let json = try! JSONSerialization.data(withJSONObject: prompts, options: [.prettyPrinted])
            print(String(data: json, encoding: .utf8)!)
            return
        }
        // Everything `clean` does to a model's reply after the HTTP call, so bench/bench.py
        // scores the text that would land at the cursor instead of the raw model output.
        // stdin: {"raw", "cleaned", "lowTouch"?, "draftTerms"?} → stdout: {"text", "lossy", "reworded"}.
        if CommandLine.arguments.contains("--finish") {
            let input = (try? JSONSerialization.jsonObject(
                with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
            let raw = input["raw"] as? String ?? ""
            let result = LLMCleaner.sanitize(input["cleaned"] as? String ?? "",
                                            fallback: LLMCleaner.ruleClean(raw))
            let lowTouch = input["lowTouch"] as? Bool ?? false
            let reworded = lowTouch && LLMCleaner.rewordsContent(
                result, raw: raw,
                allowed: LLMCleaner.allowedTerms(vocabulary: AppSettings.shared.vocabulary,
                                                 draftTerms: input["draftTerms"] as? [String] ?? []))
            let lossy = LLMCleaner.looksTruncated(result, raw: raw) || reworded
            let out: [String: Any] = ["lossy": lossy, "reworded": reworded,
                                      "text": lossy ? LLMCleaner.ruleClean(raw) : LLMCleaner.stripFillers(result)]
            print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
            return
        }
        // The whole cleanup path against a live endpoint — resolution, prompt, guards, and the
        // escalation retry — so guard-triggered escalation can be exercised without dictating.
        // stdin: {"raw", "bundleID"?, "appName"?} → stdout: {"text", "provider"}.
        if CommandLine.arguments.contains("--clean") {
            let input = (try? JSONSerialization.jsonObject(
                with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
            let context = AppContext(bundleID: input["bundleID"] as? String ?? "com.apple.terminal",
                                     appName: input["appName"] as? String ?? "Terminal",
                                     windowTitle: "")
            let cleaner = LLMCleaner()
            let result: (text: String, provider: String) = awaitSync {
                await cleaner.clean(input["raw"] as? String ?? "", context: context)
            }
            let out: [String: Any] = ["text": result.text, "provider": result.provider]
            print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
            return
        }
        // Every model on disk, one id per line, so bench/bench.py can enumerate the in-process
        // engine the same way it enumerates LM Studio's /models.
        if CommandLine.arguments.contains("--list-models") {
            for model in LocalEngine.installedModels() { print(model.id) }
            return
        }
        // In-process completions for bench/bench.py, which otherwise only speaks HTTP and so cannot
        // measure the engine that replaces it.
        //
        // A *loop* over NDJSON rather than one completion per invocation, and that is the whole point:
        // a fresh process per case would reload the model every time and report cold-load latency,
        // which is precisely the cost LM Studio was absorbing for free. Comparing a cold in-process
        // load against a warm server would answer the wrong question. One process, model loaded once,
        // every case warm — the same conditions the app runs in.
        //
        // stdin: one {"model", "messages"} object per line → stdout: one {"content", "ms"} per line.
        if CommandLine.arguments.contains("--complete") {
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty,
                      let request = (try? JSONSerialization.jsonObject(
                        with: Data(line.utf8))) as? [String: Any],
                      let model = request["model"] as? String,
                      let messages = request["messages"] as? [[String: String]]
                else { continue }
                let started = Date()
                var out: [String: Any] = [:]
                let outcome: (String?, String?) = awaitSync {
                    do { return (try await LocalEngine.shared.complete(id: model, messages: messages), nil) }
                    catch { return (nil, "\(error)") }
                }
                if let content = outcome.0 { out["content"] = content }
                if let error = outcome.1 { out["error"] = error }
                out["ms"] = Int(Date().timeIntervalSince(started) * 1000)
                let data = try! JSONSerialization.data(withJSONObject: out)
                print(String(data: data, encoding: .utf8)!)
                fflush(stdout)
            }
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
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchSystemAppearance()
        controller = DictationController()
        dashboard = DashboardWindowController(controller: controller)
        pill = RecordingPillController(controller: controller) { [weak self] section in
            self?.dashboard.show(section)
        }
        toast = ToastController(controller: controller)

        setupMenuBar()
        setupQuitShortcut()
        DictationController.requestPermissions()
        // Starting the monitor is what decides whether the macOS fn action gets suppressed:
        // it only happens while fn is one of the user's bindings.
        controller.start()
        // Wiring only: cloud sync wakes on new history entries and a slow timer, and touches
        // the network only while someone is signed in with a sync switch on.
        SyncEngine.shared.start()

        // First run: open the dashboard so permissions/setup are visible.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            dashboard.show()
        }
    }

    /// Keeps `systemIsDark` true to the OS so the System theme actually follows it. KVO on
    /// `effectiveAppearance` rather than the AppleInterfaceThemeChanged notification: that one
    /// fires before the app has taken the new appearance, so reading it back lands on the old
    /// value about half the time.
    private func watchSystemAppearance() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            DispatchQueue.main.async {
                // Only for System — every other theme states its own answer, and assigning
                // regardless would republish (and repaint) on every OS flip for no reason.
                guard AppSettings.shared.appearance == .system,
                      AppSettings.shared.systemIsDark != dark else { return }
                AppSettings.shared.systemIsDark = dark
            }
        }
        // Seed it before the first draw: the observer's .initial callback is asynchronous, and a
        // window built in between would come up light on a dark Mac and then flick.
        AppSettings.shared.systemIsDark =
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Theme.applyToNativeControls()
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
        let settings = AppSettings.shared
        let hint = settings.holdHint
        let lock = settings.shortcuts(for: .pushToTalk).isEmpty ? "" : ", double-tap to lock"
        statusItem.button?.toolTip = "Bluejay Wispr · \(hint.prefix(1).lowercased())\(hint.dropFirst())"
            + "\(lock).\nRight-click to quit."
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
