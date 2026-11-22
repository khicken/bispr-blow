import AppKit
import AVFoundation
import IOKit.hidsystem
import Speech

// The four macOS permissions the app uses. Nothing asks at launch: the first-run checklist
// on Home asks one at a time, when the user taps its button.
enum Permission: CaseIterable, Identifiable {
    case microphone, speech, accessibility, inputMonitoring

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var reason: String {
        switch self {
        case .microphone: "Hear your voice when you dictate."
        case .speech: "Turn your voice into text on this Mac."
        case .accessibility: "Type the text into the app you are using."
        case .inputMonitoring: "Detect your dictation shortcut."
        }
    }

    var pane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    // True when macOS will not show its prompt again, so the only way forward is System Settings.
    var needsSettings: Bool {
        switch self {
        case .microphone: [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech: [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
        case .accessibility: false
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
        }
    }

    static func statuses() -> [Permission: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.isGranted) })
    }

    static var allGranted: Bool { allCases.allSatisfy(\.isGranted) }

    // Shows the system prompt, or opens the pane when the prompt cannot appear again.
    func request() {
        if needsSettings { openSettings(); return }
        switch self {
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .speech: SFSpeechRecognizer.requestAuthorization { _ in }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring: IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    func openSettings() {
        Self.openSettings(pane)
    }

    static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
