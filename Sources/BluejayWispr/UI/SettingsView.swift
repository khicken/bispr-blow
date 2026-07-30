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
                        permissionRow("Input Monitoring",
                                      hint: settings.fnIsBound
                                        ? "Needed to capture the fn key"
                                        : "Needed to capture your shortcuts")
                    }
                }
            }

            settingsGroup("Shortcuts") {
                ShortcutRows(settings: settings)
            }

            settingsGroup("Appearance") {
                // Swatches rather than a menu: a theme is the one setting whose value you can only
                // judge by looking at it, so the control shows it instead of naming it.
                HStack(spacing: 10) {
                    ForEach(Appearance.allCases) { appearance in
                        ThemeSwatch(appearance: appearance,
                                    selected: settings.appearance == appearance) {
                            withAnimation(.bjSoft) { settings.appearance = appearance }
                        }
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

    /// Which model does the cleaning is plumbing, so it sits last — but it is a section like every
    /// other section. It was the one collapsible thing in the app, hiding three rows behind a
    /// disclosure nothing else on the page had, which cost a click and read as a different kind of
    /// control rather than as "the part you can ignore".
    private var advanced: some View {
        settingsGroup("Advanced") {
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

/// A theme, shown rather than described: its own surface colour, its own accent, its own bar, and
/// its brand image where it has one. Picking it is picking the picture.
struct ThemeSwatch: View {
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var palette: Palette { appearance.palette }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottom) {
                    palette.cream
                    if let name = palette.previewImage, let image = Theme.image(name) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // No image: show the palette itself, so both swatches carry the same weight.
                        LinearGradient(colors: [palette.surface, palette.surfaceActive],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    // The bar, at the size it draws, on the edge it sits on.
                    Capsule()
                        .fill(palette.pillBackground)
                        .frame(width: 46, height: 11)
                        .padding(.bottom, 9)
                }
                .frame(height: 86)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(palette.blue).frame(width: 7, height: 7)
                        Text(appearance.rawValue)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(appearance.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSubtle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(width: 188)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.blue : Theme.border,
                            lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .handCursor()
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .shadow(color: Theme.ink.opacity(hovering ? 0.08 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
        .accessibilityLabel("\(appearance.rawValue) theme")
    }
}
