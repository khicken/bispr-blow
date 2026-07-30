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
    @State private var devices = AudioRecorder.inputDevices()
    @State private var models: [String] = []
    @State private var showAdvanced = false

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let cleaner = LLMCleaner()

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

            settingsGroup("Microphone") {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.blue)
                        .symbolEffect(.bounce, value: settings.inputDeviceUID)
                    Picker("", selection: $settings.inputDeviceUID) {
                        Text(micName.isEmpty ? "System default" : "System default (\(micName))").tag("")
                        ForEach(devices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }

            advanced
        }
        .task { models = await cleaner.availableModels() }
        .onChange(of: settings.provider) { _, _ in
            Task { models = await cleaner.availableModels() }
        }
        .onChange(of: settings.preferredModel) { _, _ in
            // Load the new model and prime the prompt-prefix cache now, server-side, so the
            // next dictation isn't the one that waits for it.
            Task { await cleaner.warmUp() }
        }
        .onReceive(refresh) { _ in
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axTrusted = AXIsProcessTrusted()
            inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            micName = AudioRecorder.defaultInputDeviceName()
        }
    }

    /// Which model does the cleaning is plumbing, so it sits last and folded away.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.bjSoft) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    SectionLabel("Advanced")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.inkSubtle)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()

            if showAdvanced {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(AppSettings.Provider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)

                    if settings.provider != .custom, settings.provider != .off, !models.isEmpty {
                        Picker("Model", selection: $settings.preferredModel) {
                            Text("Automatic").tag("")
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    if settings.provider == .custom {
                        labeledField("Endpoint (…/v1)", text: $settings.customEndpoint,
                                     placeholder: "https://api.groq.com/openai/v1")
                        labeledField("Model", text: $settings.customModel,
                                     placeholder: "llama-3.3-70b-versatile")
                        labeledField("API key", text: $settings.customAPIKey, placeholder: "sk-…", secure: true)
                    }
                }
                .card()
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
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
