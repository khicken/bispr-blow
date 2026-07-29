import AppKit
import AVFoundation
import IOKit.hidsystem
import Speech

/// Central state machine: Fn gesture → record → transcribe → clean → insert → history.
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
    /// Endpoint + model cleanup resolved to, surfaced in Settings.
    @Published private(set) var cleanupModel = ""

    private var axPollTimer: Timer?
    private var keepAliveTimer: Timer?

    private let monitor = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = LLMCleaner()
    private let history = HistoryStore.shared

    private var capturedContext: AppContext?
    private var recordingStartedAt = Date()
    private var sessionGeneration = 0
    private var noteMode = false

    func start() {
        transcriber.onPartial = { [weak self] text in
            self?.partialText = text
        }
        monitor.onStart = { [weak self] in
            Task { @MainActor in self?.beginRecording() }
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

        // Until Accessibility is granted, auto-insert and fn interception are degraded —
        // keep a persistent hint on the pill and clear it the moment the grant lands.
        if !AXIsProcessTrusted() {
            notice = "Grant Accessibility for auto-insert"
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.axPollTimer?.invalidate()
                    self.axPollTimer = nil
                    self.notice = nil
                    self.showNotice("Ready. Hold fn to dictate")
                }
            }
        }

        Task.detached(priority: .utility) {
            await Transcriber.prepareAssets()
        }
        Task.detached(priority: .utility) { [cleaner] in
            await LLMCleaner.bootLMStudioIfNeeded()
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // give the server a moment
            await cleaner.warmUp()
            await MainActor.run { self.cleanupModel = cleaner.activeDescription }
        }
        // Keepalive: LM Studio idle-unloads models after ~60 min; a periodic warm call
        // keeps the model and the prompt-prefix cache hot so dictations never hit a
        // ~20s cold reload.
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [cleaner] _ in
            Task.detached(priority: .utility) {
                await cleaner.warmUp()
            }
        }
    }

    var isLocked: Bool {
        if case .recording(let locked) = state { return locked }
        return false
    }

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

    /// Pill button: dictate a quick note — saved to history and the clipboard,
    /// not pasted anywhere.
    func startQuickNote() {
        guard state == .idle else { return }
        noteMode = true
        monitor.beginLockedSession()
    }

    private func showNotice(_ message: String, for seconds: TimeInterval = 4) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }

    private func beginRecording() {
        guard state == .idle else { return }
        sessionGeneration += 1
        capturedContext = noteMode
            ? AppContext(bundleID: "", appName: "Quick Note", windowTitle: "")
            : ContextDetector.current()
        let device = AudioRecorder.defaultInputDeviceName()
        if device != UserDefaults.standard.string(forKey: "lastMicName") {
            UserDefaults.standard.set(device, forKey: "lastMicName")
            micFlash = device
        }
        recordingStartedAt = Date()
        partialText = ""
        lastError = nil
        state = .recording(locked: false)

        let format = recorder.inputFormat
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.level = level }
        }
        recorder.onBuffer = { [weak self] buffer in
            self?.transcriber.feed(buffer)
        }

        let generation = sessionGeneration
        Task {
            await transcriber.startSession(inputFormat: format)
            guard self.sessionGeneration == generation, case .recording = self.state else { return }
            do {
                try recorder.start()
            } catch {
                self.lastError = "Microphone unavailable: \(error.localizedDescription)"
                self.state = .idle
            }
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        let duration = Date().timeIntervalSince(recordingStartedAt)
        recorder.stop()
        level = 0
        state = .processing

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
                self.micFlash = nil
                self.noteMode = false
                return
            }
            let llmStart = Date()
            let (cleaned, provider) = await self.cleaner.clean(raw, context: context)
            let llmMs = Date().timeIntervalSince(llmStart) * 1000
            self.cleanupModel = self.cleaner.activeDescription
            NSLog("BluejayWispr: timings transcribe=%.0fms llm=%.0fms provider=%@ words=%d",
                  transcribeMs, llmMs, provider, cleaned.split(separator: " ").count)
            guard self.sessionGeneration == generation else { return }
            if !cleaned.isEmpty {
                if self.noteMode {
                    self.noteMode = false
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(cleaned, forType: .string)
                    self.showNotice("Note saved to history and clipboard")
                } else if !TextInserter.insert(cleaned) {
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
            self.micFlash = nil
        }
    }

    private func cancelRecording() {
        guard case .recording = state else { return }
        sessionGeneration += 1
        recorder.stop()
        level = 0
        micFlash = nil
        noteMode = false
        partialText = ""
        state = .idle
        Task { await transcriber.cancelSession() }
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
