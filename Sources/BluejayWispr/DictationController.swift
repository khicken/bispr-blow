import AppKit
import AVFoundation
import IOKit.hidsystem
import Speech

/// Central state machine: shortcut gesture → record → transcribe → clean → insert → history.
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
    /// Transient message shown on the pill (e.g. manual-paste fallback).
    @Published private(set) var notice: String?
    /// Device name flashed on the pill — only when the input device changed since last time.
    /// The current device is always visible in Settings.
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
    /// Set by the "dictate and send" binding: press Return once the text is in.
    private var sendEnter = false

    func start() {
        transcriber.onPartial = { [weak self] text in
            self?.partialText = text
        }
        monitor.onStart = { [weak self] sendEnter in
            Task { @MainActor in self?.beginRecording(sendEnter: sendEnter) }
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

    /// `--pill-demo` only: replays a release transition with no mic, no model and no event tap, so
    /// the pill's animation can be measured instead of described.
    func demoState(_ state: State) { self.state = state }

    /// Reflect lock state in UI when the monitor transitions hold → locked.
    func noteLocked() {
        if case .recording = state { state = .recording(locked: true) }
    }

    /// Stop button on the pill during a hands-free session.
    func stopHandsFree() {
        monitor.endLockedSession()
    }

    /// Pill button: start a hands-free dictation into the focused app.
    func startHandsFree() {
        guard state == .idle else { return }
        monitor.beginLockedSession()
    }

    private func showNotice(_ message: String, for seconds: TimeInterval = 4) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }

    private func beginRecording(sendEnter: Bool) {
        guard state == .idle else { return }
        ActivationTrace.mark("onStart")
        sessionGeneration += 1
        self.sendEnter = sendEnter
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
        Self.playSound("Tink")
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

        // Whether the focused field's text actually reaches us is per-app and unmeasured — some
        // apps expose nothing over Accessibility, and recognizer biasing is only as good as this.
        // Counts, never the text itself: the unified log is readable by anything on the machine.
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
                self.state = .idle
                return
            }
            // The pill says "recording" from the moment the shortcut fires, but the mic only opens
            // here — everything spoken while the analyzer was spinning up was never captured by
            // anything. Reported against the gesture edge alongside the other activation stages,
            // so the old "ms after shortcut" number is still there as `mic` minus `onStart`.
            ActivationTrace.mark("mic")
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        recorder.stop()
        level = 0
        state = .processing

        // Nothing was captured, so there is nothing to finalise — and finalising anyway is not
        // merely pointless, it hangs: `finalizeAndFinishThroughEndOfInput` never returns on an
        // analyzer that was never fed, which left the pill spinning on the dots until the app was
        // force-quit. A capture that produced no audio is a failure the user has to be told about,
        // because the alternative is dictating into nothing and not finding out.
        guard recorder.capturedFrames > 0 else {
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
        Task {
            let released = Date()
            let raw = await transcriber.finishSession()
            let transcribeMs = Date().timeIntervalSince(released) * 1000
            guard self.sessionGeneration == generation else { return }
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
                Self.playSound("Pop")
                if !TextInserter.insert(cleaned, thenReturn: self.sendEnter) {
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
        guard case .recording = state else { return }
        sessionGeneration += 1
        recorder.stop()
        level = 0
        sendEnter = false
        partialText = ""
        state = .idle
        Task { await transcriber.cancelSession() }
    }

    /// One click when the mic opens, one when the text lands. Fire and forget: you are looking at
    /// the app you dictated into, not at the pill, and a sound that waits on anything is late.
    private static func playSound(_ name: String) {
        guard AppSettings.shared.soundsEnabled else { return }
        NSSound(named: name)?.play()
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
