import AppKit
import AVFoundation
import IOKit.hidsystem
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @State private var micName = AudioRecorder.defaultInputDeviceName()

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Page(title: "Settings") {
            // Only shown while something actually needs the user's attention.
            if !micGranted || !axTrusted || !inputMonitoringGranted {
                settingsGroup("Needs attention") {
                    if !micGranted {
                        permissionRow("Microphone", hint: "System Settings, Privacy & Security, Microphone")
                    }
                    if !axTrusted {
                        permissionRow("Accessibility", hint: "System Settings, Privacy & Security, Accessibility")
                    }
                    if !inputMonitoringGranted {
                        permissionRow("Input Monitoring", hint: "Needed to capture the fn key")
                    }
                }
            }

            settingsGroup("AI cleanup") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AppSettings.Provider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)

                Text(providerHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSubtle)

                if settings.provider == .custom {
                    labeledField("Endpoint (…/v1)", text: $settings.customEndpoint,
                                 placeholder: "https://api.groq.com/openai/v1")
                    labeledField("Model", text: $settings.customModel,
                                 placeholder: "llama-3.3-70b-versatile")
                    labeledField("API key", text: $settings.customAPIKey, placeholder: "sk-…", secure: true)
                }
            }

            settingsGroup("Microphone") {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.blue)
                    Text(micName.isEmpty ? "No input device" : micName)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Text("Uses the system default input.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSubtle)
            }

            // Only route out of the app — the menu bar icon just opens this window.
            Button("Quit Bluejay Wispr") { NSApp.terminate(nil) }
                .buttonStyle(QuietButtonStyle())
        }
        .onReceive(refresh) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axTrusted = AXIsProcessTrusted()
            inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            micName = AudioRecorder.defaultInputDeviceName()
        }
    }

    private var providerHint: String {
        switch settings.provider {
        case .auto: return "Tries LM Studio, then Ollama. Falls back to basic cleanup if neither is running."
        case .lmStudio: return "Uses the best chat model in LM Studio."
        case .ollama: return "Uses the first model available in Ollama."
        case .custom: return "Any OpenAI-compatible endpoint, like Groq or Gemini."
        case .off: return "Inserts the raw transcript with basic filler removal only."
        }
    }

    @ViewBuilder
    private func settingsGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .card()
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSubtle)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            )
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func permissionRow(_ name: String, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.red)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSubtle)
        }
    }
}
