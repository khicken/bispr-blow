import AppKit
import AVFoundation
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
    @Published private(set) var level: Float = 0
    @Published private(set) var partialText = ""
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
    // Set by the "dictate and send" binding: press Return once the text is in.
    private var sendEnter = false
    // A voice-command session runs what was said each time the speaker pauses, so a held press runs
    // one command and a double-tapped one stays on and keeps acting until it is tapped off.
    private var isCommand = false
    // Settled words not yet run, and whether any arrived: the SFSpeechRecognizer fallback never
    // settles anything mid-session, so its whole transcript runs at release instead.
    private var commandPending = ""
    private var commandSettledAny = false
    private var commandSnapshot = ""
    private var commandHeardAt = Date()
    private var commandPauseTimer: Timer?
    private var commandQueue: Task<Void, Never>?
    // Bumped by Esc and by every new session; a queued command checks it before each step, since
    // cancelling the newest Task does not reach the ones it is waiting behind.
    private var commandEpoch = 0
    private static let commandPause: TimeInterval = 0.8

    func start() {
        transcriber.onPartial = { [weak self] text in
            guard let self else { return }
            partialText = text
            // Settling repeats the same words; only new words mean the speaker is still talking.
            if isCommand, text != commandSnapshot {
                commandSnapshot = text
                commandHeardAt = Date()
            }
        }
        transcriber.onFinal = { [weak self] settled in
            guard let self, isCommand, !settled.isEmpty else { return }
            // Settled chunks arrive trimmed, so "go to" and "LinkedIn" need their space put back.
            commandPending += commandPending.isEmpty ? settled : " " + settled
            commandSettledAny = true
        }
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
            notice = "Grant Accessibility for auto-insert"
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
            logLine("cleanup using \(cleaner.activeDescription)")
        }
    }

    var isLocked: Bool {
        if case .recording(let locked) = state { return locked }
        return false
    }

    // `--pill-demo` only: replays a release transition with no mic, no model and no event tap, so
    // the pill's animation can be measured instead of described.
    func demoState(_ state: State) { self.state = state }

    // Reflect lock state in UI when the monitor transitions hold → locked.
    func noteLocked() {
        if case .recording = state { state = .recording(locked: true) }
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

    private func showNotice(_ message: String, for seconds: TimeInterval = 4,
                           action: (label: String, run: () -> Void)? = nil) {
        notice = message
        noticeAction = action
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.notice == message {
                self?.notice = nil
                self?.noticeAction = nil
            }
        }
    }

    private func beginRecording(_ action: ShortcutAction) {
        guard state == .idle else { return }
        // Speaking again means the last dictation's edits are done, before this one's text can land beside them.
        CorrectionWatcher.cancel()
        ActivationTrace.mark("onStart")
        sessionGeneration += 1
        sendEnter = action == .pressEnter
        isCommand = action == .command
        if isCommand {
            commandPending = ""
            commandSettledAny = false
            commandSnapshot = ""
            commandHeardAt = Date()
            commandEpoch += 1
            commandPauseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.runCommandIfPaused() }
            }
        }
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
        partialText = ""
        lastError = nil
        state = .recording(locked: false)

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.level = level }
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
        Task {
            await transcriber.startSession(contextTerms: capturedContext?.draftTerms ?? [])
            ActivationTrace.mark("session")
            guard self.sessionGeneration == generation, case .recording = self.state else { return }
            do {
                try recorder.start()
            } catch {
                self.lastError = "Microphone unavailable: \(error.localizedDescription)"
                self.endCommandSession(runningRestOf: nil)
                self.state = .idle
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
        level = 0
        state = .processing

        // Nothing was captured, so there is nothing to finalise — and finalising anyway hangs:
        // `finalizeAndFinishThroughEndOfInput` never returns on an analyzer that was never fed, which
        // left the pill spinning until the app was force-quit. Silence is a failure the user has to
        // be told about.
        guard recorder.capturedFrames > 0 else {
            endCommandSession(runningRestOf: nil)
            logLine("dictation discarded: no audio captured")
            sessionGeneration += 1
            Task { await transcriber.cancelSession() }
            showNotice("No audio from \(AudioRecorder.currentInputDeviceName())")
            state = .idle
            partialText = ""
            sendEnter = false
            return
        }

        let context = capturedContext ?? ContextDetector.current()
        let generation = sessionGeneration
        // Captured now: Esc while this finalizes ends the session, and must not turn a command into typed text.
        let wasCommand = isCommand
        Task {
            let released = Date()
            let raw = await transcriber.finishSession()
            let transcribeMs = Date().timeIntervalSince(released) * 1000
            guard self.sessionGeneration == generation else { return }
            if wasCommand {
                self.endCommandSession(runningRestOf: raw)
                await self.commandQueue?.value
                self.state = .idle
                self.partialText = ""
                return
            }
            guard !raw.isEmpty else {
                self.state = .idle
                self.partialText = ""
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
            self.partialText = ""
            self.sendEnter = false
        }
    }

    private func cancelRecording() {
        CorrectionWatcher.cancel()
        // Esc stops a command session outright, including commands heard but not yet run.
        commandEpoch += 1
        commandQueue?.cancel()
        endCommandSession(runningRestOf: nil)
        guard case .recording = state else { return }
        sessionGeneration += 1
        recorder.stop()
        level = 0
        sendEnter = false
        partialText = ""
        state = .idle
        Task { await transcriber.cancelSession() }
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

    private func runCommandIfPaused() {
        guard Date().timeIntervalSince(commandHeardAt) >= Self.commandPause,
              !VoiceCommand.isUnfinished(commandPending) else { return }
        queueCommand(commandPending)
        commandPending = ""
    }

    private func queueCommand(_ said: String) {
        let said = VoiceCommand.withoutLeadingJoint(said)
        guard !said.isEmpty else { return }
        let previous = commandQueue, epoch = commandEpoch
        commandQueue = Task { [weak self] in
            await previous?.value
            await self?.runCommand(said, epoch: epoch)
        }
    }

    // Release runs whatever has settled since the last pause; the fallback recognizer, which
    // settles nothing early, hands over its whole transcript here.
    private func endCommandSession(runningRestOf heard: String?) {
        commandPauseTimer?.invalidate()
        commandPauseTimer = nil
        if isCommand, let heard { queueCommand(commandSettledAny ? commandPending : heard) }
        commandPending = ""
        isCommand = false
    }

    // The front app's screen is read, one element in it is acted on, and anything Jev is unsure of
    // is asked about rather than done. Labels stay out of the log: they are someone's screen.
    private func runCommand(_ spoken: String, epoch: Int) async {
        guard AppSettings.shared.voiceCommands else {
            showNotice("Turn on Voice commands in Settings")
            return
        }
        for (index, step) in VoiceCommand.steps(in: spoken).enumerated() {
            // The last step changed the screen; the app needs a beat to draw it before it is read again.
            if index > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            guard epoch == commandEpoch, let app = NSWorkspace.shared.frontmostApplication,
                  await runStep(step, in: app, epoch: epoch)
            else { return }
        }
    }

    // True when the step was done; false when it was asked about or failed, which ends the chain.
    private func runStep(_ spoken: String, in app: NSRunningApplication, epoch: Int) async -> Bool {
        let readStarted = Date()
        let elements = await Task.detached { ScreenElements.read(app: app) }.value
        guard epoch == commandEpoch else { return false }
        let readMs = Int(Date().timeIntervalSince(readStarted) * 1000)
        if let target = VoiceCommand.appNamed(in: spoken, among: elements) {
            logLine("command app-switch read=\(readMs)ms")
            guard VoiceCommand.perform(target, spoken: spoken) else {
                showNotice("Couldn't switch to \(target.label)")
                return false
            }
            return true
        }
        do {
            let pickStarted = Date()
            let pick = try await VoiceCommand.pick(spoken, among: elements, appName: app.localizedName ?? "the app in front")
            guard epoch == commandEpoch else { return false }
            logLine("command read=\(readMs)ms jev=\(Int(Date().timeIntervalSince(pickStarted) * 1000))ms choices=\(elements.count) confidence=\(pick.confidence)")
            guard pick.confidence >= VoiceCommand.confidentEnough, !VoiceCommand.needsConfirmation(pick.element) else {
                let pid = app.processIdentifier
                showNotice("\(pick.confidence >= VoiceCommand.confidentEnough ? "Press" : "Did you mean") \(pick.element.label)?", for: 8,
                           action: ("Do it", { [weak self] in
                               // The element belongs to the app the command was said in; elsewhere it presses nothing sensible.
                               guard epoch == self?.commandEpoch,
                                     NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                                     VoiceCommand.perform(pick.element, spoken: spoken)
                               else { self?.showNotice("Couldn't do that: \(pick.element.label)"); return }
                           }))
                return false
            }
            guard VoiceCommand.perform(pick.element, spoken: spoken) else {
                showNotice("Couldn't do that: \(pick.element.label)")
                return false
            }
            return true
        } catch VoiceCommand.Failure.noKey {
            showNotice("Voice commands need a TypeSafe key in your Keychain")
        } catch VoiceCommand.Failure.keyRejected {
            showNotice("TypeSafe rejected the key in your Keychain")
        } catch {
            // Esc cancels the request in flight; that is the user stopping, not Jev failing.
            guard epoch == commandEpoch else { return false }
            logLine("command failed error=\(error.localizedDescription)")
            showNotice("Couldn't reach Jev")
        }
        return false
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
