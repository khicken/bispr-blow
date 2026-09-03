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
        // Drives the real `AudioRecorder` for two seconds and reports what arrived, because the
        // alternative is finding out at the cursor. A dictation cannot be triggered without the
        // keyboard, so before this the capture path was the one part of the app that could only be
        // tested by asking Kaleb — which is how an input-only mic capturing nothing shipped twice.
        // Exercises the selected device, so run it after changing the mic in Settings.
        if CommandLine.arguments.contains("--mic-check") {
            let recorder = AudioRecorder()
            print("device: \(AudioRecorder.currentInputDeviceName())")
            do {
                let started = Date()
                try recorder.start()
                print("startup: \(Int(Date().timeIntervalSince(started) * 1000))ms")
            } catch {
                print("FAIL — start threw: \(error.localizedDescription)")
                exit(1)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let frames = recorder.capturedFrames
            recorder.stop()
            print("frames: \(frames)")
            print(frames > 0 ? "PASS — see the `audio` line in the log for level"
                             : "FAIL — no audio captured")
            exit(frames > 0 ? 0 : 1)
        }
        // Replays a release transition and measures the pill's drawn position every 8ms, because
        // the alternative is asking Kaleb what he saw — which is how two attempts at this animation
        // shipped a regression. Same idea as `--mic-check`: make the thing observable first.
        if CommandLine.arguments.contains("--pill-demo") {
            PillDemo.run()
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
        // The dictionary respeller alone, against the real dictionary, one line of stdin per case.
        // It exists because vocabulary corruption has now shipped twice and neither time was
        // reachable from a test: the damage happens after the model, so `--clean` hides it behind
        // an endpoint and `--finish` never calls this at all.
        if CommandLine.arguments.contains("--vocab") {
            let vocab = AppSettings.shared.vocabulary
            while let line = readLine(strippingNewline: true) {
                print(LLMCleaner.applyVocabulary(line, vocabulary: vocab))
            }
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
            // The same guard set the app runs, from the same function, because these two lists had
            // drifted: this one never ran `losesContent`, so the bench was scoring a laxer app than
            // the one that ships. `reason` is reported so a bench run says which guard fired.
            let why = LLMCleaner.rejection(
                result, raw: raw, lowTouch: lowTouch,
                allowed: LLMCleaner.allowedTerms(vocabulary: AppSettings.shared.vocabulary,
                                                 draftTerms: input["draftTerms"] as? [String] ?? []))
            let out: [String: Any] = ["lossy": why != nil, "reworded": why == .reworded,
                                      "reason": why?.rawValue ?? NSNull(),
                                      "text": why != nil ? LLMCleaner.ruleClean(raw)
                                                         : LLMCleaner.stripFillers(result)]
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
            // Warm first, as the app does at launch: a cold model load eats the whole deadline,
            // so without this every long case reports a deadline miss instead of exercising the
            // guards and the escalation the seam exists to verify.
            let result: (text: String, provider: String) = awaitSync {
                await cleaner.warmUp()
                return await cleaner.clean(input["raw"] as? String ?? "", context: context)
            }
            let out: [String: Any] = ["text": result.text, "provider": result.provider]
            print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
            return
        }
        // Whether accounts are switched on, and where they point. Worth a seam because the answer
        // used to depend on a per-user `defaults write`: `ready` was true on the machine where
        // someone had run it and false in every installed copy, and nothing printed either way.
        if CommandLine.arguments.contains("--cloud-check") {
            print("ready=\(CloudConfig.ready)")
            print("url=\(CloudConfig.url?.absoluteString ?? "none")")
            print("key=\(CloudConfig.anonKey.isEmpty ? "none" : String(CloudConfig.anonKey.prefix(18)) + "…")")
            print("callback=\(CloudConfig.callbackURL)")
            print("session=\(CloudClient.storedSessionEmail().map { "signed in as \($0)" } ?? "signed out")")
            return
        }
        // Drives the real `ModelDownloader` against Hugging Face and prints progress. The installer
        // no longer ships the Accurate weights, so this is the only way anyone gets them — worth a
        // seam, because before this existed the whole path had been read and never once run.
        if CommandLine.arguments.contains("--download-accurate") {
            let downloader = ModelDownloader.shared
            print("downloading \(ModelDownloader.modelName)…")
            downloader.start { print("done"); exit(0) }
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if let failure = downloader.failure { print("failed: \(failure)"); exit(1) }
                if let fraction = downloader.fraction {
                    print(String(format: "%.1f%%", fraction * 100))
                    fflush(stdout)
                }
            }
            RunLoop.main.run()
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
        // Menu-bar app with no Dock icon unless the user asked for one.
        app.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
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
        toast = ToastController(controller: controller, model: pill.model)

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
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "BisprBlow")
            }
        }

        // Left-click opens the app; right-click is the one place Quit lives.
        quitMenu = NSMenu()
        quitMenu.addItem(withTitle: "Quit BisprBlow",
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let settings = AppSettings.shared
        let hint = settings.holdHint
        let lock = settings.shortcuts(for: .pushToTalk).isEmpty ? "" : ", double-tap to lock"
        statusItem.button?.toolTip = "BisprBlow · \(hint.prefix(1).lowercased())\(hint.dropFirst())"
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
        appMenu.addItem(withTitle: "Quit BisprBlow",
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

    /// The sign-in link in the emailed code lands here — `bisprblow://auth-callback` with the
    /// tokens in the fragment (`CFBundleURLTypes` in Info.plist registers the scheme). The Google
    /// sheet does not: `ASWebAuthenticationSession` intercepts its own callback, so this is only
    /// the email half. A failure shows the dashboard anyway — an expired link has to say so
    /// somewhere, and the sign-in card is where the user was headed.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let callback = urls.first(where: { $0.scheme == CloudConfig.callbackScheme })
        else { return }
        dashboard.show(.team)
        Task { @MainActor in
            do { try await CloudClient.shared.signIn(callback: callback) }
            catch { logLine("cloud: email link sign-in failed: \(error.localizedDescription)") }
        }
    }

    /// `open BisprBlow.app` while running (or Dock/Launchpad click) reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemFnKey.restore()
    }
}
