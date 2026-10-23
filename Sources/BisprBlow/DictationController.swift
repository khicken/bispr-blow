import AppKit
import AVFoundation
import Combine
import IOKit.hidsystem
import Speech

// Central state machine: shortcut gesture → record → transcribe → clean → insert → history.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(locked: Bool)
        case processing
    }

    @Published private(set) var state: State = .idle
    // Mic level for the pill's wave, ~43 a second while recording. A subject, not @Published, so
    // views that observe the controller for its state do not redraw at that rate.
    let levels = PassthroughSubject<Float, Never>()
    @Published private(set) var lastError: String?
    // Transient message shown on the pill (e.g. manual-paste fallback).
    @Published private(set) var notice: String?
    // A button on the current notice, when the notice is about something the app did on its own.
    // Only the learned-a-word message uses it: changing the user's dictionary without asking has to
    // offer the way back in the same breath.
    @Published private(set) var noticeAction: (label: String, run: () -> Void)?
    // Device name flashed on the pill — only when the input device changed since last time.
    // The current device is always visible in Settings.
    @Published private(set) var micFlash: String?

    private var axPollTimer: Timer?

    private let monitor = ShortcutMonitor.shared
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = LLMCleaner()
    private let history = HistoryStore.shared

    private var capturedContext: AppContext?
    private var recordingStartedAt = Date()
    private var sessionGeneration = 0
    // This dictation's transcriber start, awaited by a cancel so an analyzer still starting is cancelled too.
    private var startTask: Task<Void, Never>?
    // Set by the "dictate and send" binding: press Return once the text is in.
    private var sendEnter = false
    // Set by the "voice command" binding: act on the app that was in front at the press.
    private var commandApp: NSRunningApplication?
    // The Electron tree a voice command turned on, and the work that turns it off again.
    private var pendingTreeClose: (pid: pid_t, work: DispatchWorkItem)?

    func start() {
        monitor.onStart = { [weak self] action in
            Task { @MainActor in self?.beginRecording(action) }
        }
        monitor.onStop = { [weak self] _ in
            Task { @MainActor in self?.finishRecording() }
        }
        monitor.onCancel = { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        monitor.onLock = { [weak self] in
            Task { @MainActor in self?.noteLocked() }
        }
        monitor.start()

        // Until Accessibility is granted, auto-insert and shortcut interception are degraded —
        // keep a persistent hint on the pill and clear it the moment the grant lands.
        if !AXIsProcessTrusted() {
            notice = Self.accessibilityHint
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.axPollTimer?.invalidate()
                    self.axPollTimer = nil
                    self.notice = nil
                    self.showNotice("Ready. \(AppSettings.shared.holdHint)")
                }
            }
        }

        Self.preloadSounds()
        Task.detached(priority: .utility) {
            await Transcriber.prepareAssets()
        }
        Task.detached(priority: .utility) { [cleaner] in
            await cleaner.warmUp()
            logLine("cleanup using \(await cleaner.activeDescription)")
        }
    }

    // `--pill-demo` only: replays a release transition with no mic, no model and no event tap, so
    // the pill's animation can be measured instead of described.
    func demoState(_ state: State) { self.state = state }

    // Reflect lock state in UI when the monitor transitions hold → locked.
    func noteLocked() {
        if case .recording = state { state = .recording(locked: true) } else { monitor.reset() }
    }

    // Stop button on the pill during a hands-free session.
    func stopHandsFree() {
        monitor.endLockedSession()
    }

    // Pill button: start a hands-free dictation into the focused app.
    func startHandsFree() {
        guard state == .idle else { return }
        monitor.beginLockedSession()
    }

    private static let accessibilityHint = "Allow Accessibility to insert text"

    private func showNotice(_ message: String, for seconds: TimeInterval = 4,
                           action: (label: String, run: () -> Void)? = nil) {
        notice = message
        noticeAction = action
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.notice == message else { return }
            // The Accessibility hint stays until access is granted.
            self.notice = self.axPollTimer == nil ? nil : Self.accessibilityHint
            self.noticeAction = nil
        }
    }

    private func beginRecording(_ action: ShortcutAction) {
        guard state == .idle else {
            monitor.reset()
            return
        }
        // Speaking again means the last dictation's edits are done, before this one's text can land beside them.
        CorrectionWatcher.cancel()
        Task.detached(priority: .utility) { [cleaner] in await cleaner.prepare() }
        ActivationTrace.mark("onStart")
        sessionGeneration += 1
        sendEnter = action == .pressEnter
        commandApp = action == .command ? NSWorkspace.shared.frontmostApplication : nil
        capturedContext = ContextDetector.current()
        let device = AudioRecorder.currentInputDeviceName()
        if device != UserDefaults.standard.string(forKey: "lastMicName") {
            UserDefaults.standard.set(device, forKey: "lastMicName")
            micFlash = device
            // Fades on its own rather than living for the whole dictation: it is a passing
            // heads-up, and the current device is always in Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.micFlash == device { self?.micFlash = nil }
            }
        }
        Self.playSound(Self.startSound)
        recordingStartedAt = Date()
        lastError = nil
        state = .recording(locked: false)

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.levels.send(level) }
        }
        recorder.onBuffer = { [weak self] buffer in
            self?.transcriber.feed(buffer)
        }

        // Whether the focused field's text reaches us is per-app and unmeasured, and recognizer
        // biasing is only as good as this. Counts, never the text: the unified log is world-readable.
        if let context = capturedContext {
            logLine("""
                context app=\(context.appName.isEmpty ? "unknown" : context.appName) \
                category=\(context.category.rawValue) title=\(context.windowTitle.count)chars \
                draft=\(context.draft.count)chars terms=\(context.draftTerms.count)
                """)
        }

        let generation = sessionGeneration
        recorder.resetCapturedFrames()
        startTask = Task {
            await transcriber.startSession(contextTerms: capturedContext?.draftTerms ?? [])
            ActivationTrace.mark("session")
            guard self.sessionGeneration == generation, case .recording = self.state else { return }
            do {
                try recorder.start()
            } catch {
                self.lastError = "Microphone unavailable: \(error.localizedDescription)"
                self.state = .idle
                self.monitor.reset()
                await self.transcriber.cancelSession()
                return
            }
            // The pill says "recording" from the moment the shortcut fires, but the mic only opens
            // here — anything spoken while the analyzer span up was captured by nothing. Reported
            // against the gesture edge, so "ms after shortcut" is `mic` minus `onStart`.
            ActivationTrace.mark("mic")
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        recorder.stop()
        levels.send(0)
        state = .processing

        // Nothing was captured, so there is nothing to finalise — and finalising anyway hangs:
        // `finalizeAndFinishThroughEndOfInput` never returns on an analyzer that was never fed, which
        // left the pill spinning until the app was force-quit. Silence is a failure the user has to
        // be told about.
        guard recorder.capturedFrames > 0 else {
            logLine("dictation discarded: no audio captured")
            sessionGeneration += 1
            cancelTranscriber()
            showNotice("No audio from \(AudioRecorder.currentInputDeviceName())")
            state = .idle
            sendEnter = false
            return
        }

        let context = capturedContext ?? ContextDetector.current()
        let generation = sessionGeneration
        Task {
            let released = Date()
            let raw = await transcriber.finishSession()
            let transcribeMs = Date().timeIntervalSince(released) * 1000
            guard self.sessionGeneration == generation else { return }
            guard !raw.isEmpty else {
                self.state = .idle
                return
            }
            if let app = self.commandApp {
                self.commandApp = nil
                await self.runCommand(raw, in: app)
                self.state = .idle
                return
            }
            let llmStart = Date()
            let (cleaned, provider) = await self.cleaner.clean(raw, context: context)
            let llmMs = Date().timeIntervalSince(llmStart) * 1000
            logLine("""
                timings transcribe=\(Int(transcribeMs))ms llm=\(Int(llmMs))ms \
                spoke=\(Int(duration * 1000))ms provider=\(provider) \
                words=\(cleaned.split(separator: " ").count)
                """)
            guard self.sessionGeneration == generation else { return }
            if !cleaned.isEmpty {
                Self.playSound(Self.endSound)
                if TextInserter.insert(cleaned, thenReturn: self.sendEnter) {
                    self.watchForCorrection(to: cleaned)
                } else {
                    self.showNotice("Copied. Press ⌘V to paste")
                }
                self.history.add(DictationEntry(
                    id: UUID(),
                    date: Date(),
                    raw: raw,
                    cleaned: cleaned,
                    appName: context.appName,
                    bundleID: context.bundleID,
                    provider: provider,
                    durationSeconds: duration
                ))
            }
            self.state = .idle
            self.sendEnter = false
        }
    }

    private func cancelRecording() {
        CorrectionWatcher.cancel()
        guard case .recording = state else { return }
        sessionGeneration += 1
        recorder.stop()
        levels.send(0)
        sendEnter = false
        state = .idle
        cancelTranscriber()
    }

    // Skipped once a newer dictation has started: the transcriber holds one session at a time.
    private func cancelTranscriber() {
        let generation = sessionGeneration
        Task { [startTask] in
            await startTask?.value
            guard self.sessionGeneration == generation else { return }
            await self.transcriber.cancelSession()
        }
    }

    // One cue when the mic opens, one when the text lands. Fire and forget: a sound that waits on
    // anything is late.
    //
    // Not `Tink`: that is the tick macOS plays for a keystroke it refuses, so using it for
    // "recording started" told the user their shortcut had failed on every dictation — reported as
    // "the invalid key input sound". Anything the system has already assigned a meaning to is out for
    // the same reason (`Basso`, `Funk`, `Sosumi`, `Frog` are alert sounds). `Purr` is unclaimed and
    // audibly different from `Pop`, which is the whole job when two sounds are all that tell you
    // whether a dictation began or ended.
    //
    // Held as instances because `NSSound(named:)` reads from disk on first use and the start cue
    // fires on the pre-mic path; `preloadSounds` pays that at launch. `stop()` before `play()`
    // because a reused instance ignores `play()` while still playing.
    private static let startSound = NSSound(named: "Purr")
    private static let endSound = NSSound(named: "Pop")

    static func preloadSounds() {
        _ = startSound
        _ = endSound
    }

    private static func playSound(_ sound: NSSound?) {
        guard AppSettings.shared.soundsEnabled else { return }
        sound?.stop()
        sound?.play()
    }

    // A word the user fixed by hand goes into the dictionary, so the next dictation spells it their
    // way. Said out loud on the pill with the way back attached: this changes a setting the user
    // owns, and doing that silently is how a dictionary starts respelling good words. Replayed over
    // history first for the same reason; the dictations still holding the mishear are the ones the
    // fix is for, so they are not evidence against it.
    private func watchForCorrection(to inserted: String) {
        CorrectionWatcher.watch(inserted: inserted) { [weak self] fix in
            let settings = AppSettings.shared
            let vocabulary = settings.vocabulary
            let known = Set(vocabulary.map { $0.lowercased() })
            let words = LLMCleaner.learnedWords(from: fix).filter { !known.contains($0.lowercased()) }
            guard !words.isEmpty else { return }
            let history = HistoryStore.shared.entries.map(\.cleaned)
                .filter { !$0.localizedCaseInsensitiveContains(fix.misheard) }
            Task {
                let safe = await Task.detached {
                    LLMCleaner.harmless(words, vocabulary: vocabulary, dictations: history)
                }.value
                logLine("correction learned=\(safe.count) skipped=\(words.count - safe.count)")
                guard !safe.isEmpty else { return }
                settings.addDictionaryWords(safe)
                self?.showNotice("Added \(safe.map { "\"\($0)\"" }.joined(separator: ", ")) to your dictionary", for: 6,
                                 action: ("Undo", { settings.dictionary.removeAll { safe.contains($0) } }))
            }
        }
    }

    // The front app's screen is read, one element in it is acted on, and anything Jev is unsure of
    // is asked about rather than done. Labels stay out of the log: they are someone's screen.
    private func runCommand(_ spoken: String, in app: NSRunningApplication) async {
        guard AppSettings.shared.voiceCommands else {
            showNotice("Turn on Voice commands in Settings")
            return
        }
        let readStarted = Date()
        // A close still pending from the last command in this app means the tree is ours and on.
        let pid = app.processIdentifier
        let opened: Bool
        if let pending = pendingTreeClose, pending.pid == pid {
            pending.work.cancel()
            pendingTreeClose = nil
            opened = true
        } else {
            opened = await Task.detached { ScreenElements.openTree(app) }.value
        }
        // After the command, or after the confirm notice expires, since "Do it" presses an element.
        // The write goes off main: a hung app answers it after the 6s default.
        var closeAfter: TimeInterval = 0
        defer {
            if opened {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.pendingTreeClose?.pid == pid { self?.pendingTreeClose = nil }
                    }
                    DispatchQueue.global().async { ScreenElements.closeTree(app) }
                }
                pendingTreeClose = (pid, work)
                DispatchQueue.main.asyncAfter(deadline: .now() + closeAfter, execute: work)
            }
        }
        let elements = await Task.detached { ScreenElements.read(app: app) }.value
        let readMs = Int(Date().timeIntervalSince(readStarted) * 1000)
        if let target = VoiceCommand.appNamed(in: spoken, among: elements) {
            logLine("command app-switch read=\(readMs)ms")
            if !VoiceCommand.perform(target, spoken: spoken) { showNotice("Couldn't switch to \(target.label)") }
            return
        }
        do {
            let pickStarted = Date()
            let pick = try await VoiceCommand.pick(spoken, among: elements, appName: app.localizedName ?? "the app in front")
            logLine("command read=\(readMs)ms jev=\(Int(Date().timeIntervalSince(pickStarted) * 1000))ms choices=\(elements.count) confidence=\(pick.confidence)")
            guard pick.confidence >= VoiceCommand.confidentEnough, !VoiceCommand.needsConfirmation(pick.element) else {
                closeAfter = 9
                showNotice("\(pick.confidence >= VoiceCommand.confidentEnough ? "Press" : "Did you mean") \(pick.element.label)?", for: 8,
                           action: ("Do it", { [weak self] in
                               // The element belongs to the app the command was said in; elsewhere it presses nothing sensible.
                               guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                                     VoiceCommand.perform(pick.element, spoken: spoken)
                               else { self?.showNotice("Couldn't do that: \(pick.element.label)"); return }
                           }))
                return
            }
            if !VoiceCommand.perform(pick.element, spoken: spoken) {
                showNotice("Couldn't do that: \(pick.element.label)")
            }
        } catch VoiceCommand.Failure.noKey {
            showNotice("Voice commands need a TypeSafe key in your Keychain")
        } catch VoiceCommand.Failure.keyRejected {
            showNotice("TypeSafe rejected the key in your Keychain")
        } catch {
            logLine("command failed error=\(error.localizedDescription)")
            showNotice("Couldn't reach Jev")
        }
    }

    // MARK: - Permissions

    static func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Keyboard event taps additionally need Input Monitoring on modern macOS.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }
}
