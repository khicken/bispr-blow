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
                // judge by looking at it, so the control shows it instead of naming it. A grid
                // rather than a row, because five no longer fit across the content pane and the
                // window resizes down to 760.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 200),
                                             spacing: 10, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Appearance.allCases) { appearance in
                        ThemeSwatch(appearance: appearance,
                                    selected: settings.appearance == appearance) {
                            withAnimation(.bjSoft) { settings.appearance = appearance }
                        }
                    }
                }
            }

            // Not "Transcription": nothing here reaches the recognizer, so a heading that named it
            // would promise that Accurate mishears fewer words. And not "Cleanup", which is our
            // word for our second stage. Both settings decide how the app writes what it heard.
            settingsGroup("Writing", padding: 5) {
                ForEach(AppSettings.Cleanup.allCases) { mode in
                    ChoiceRow(title: mode.rawValue,
                              detail: mode.detail,
                              selected: settings.cleanup == mode) {
                        withAnimation(.bjSnap) { settings.cleanup = mode }
                    }
                }
                // Two of the three rows are one choice; the rule says so, so the switch does not
                // read as a third mode.
                Rectangle()
                    .fill(Theme.border.opacity(0.5))
                    .frame(height: 1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 3)
                // What survives the lowercasing is real, but it is reassurance rather than
                // something to act on, so it goes in a tooltip (CLAUDE.md) instead of a line of
                // grey text under a one-line setting.
                ToggleRow("Start sentences in lowercase",
                          help: "Names, acronyms, and your dictionary keep their capitals.",
                          isOn: $settings.lowercaseSentences)
            }

            settingsGroup("Microphone", padding: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.bj(12))
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
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                Rectangle()
                    .fill(Theme.border.opacity(0.5))
                    .frame(height: 1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 3)
                ToggleRow("Keep the mic loud enough",
                          help: "Video call apps often turn the microphone down and leave it there, which makes dictation mishear. Turns it back up before each dictation. Never turns it down.",
                          isOn: $settings.restoreMicVolume)
            }

            // Only in builds where a project is configured — an Account section that can never
            // sign in is a promise the app cannot keep.
            if CloudConfig.ready {
                settingsGroup("Account", padding: 5) {
                    AccountSection(cloud: CloudClient.shared, settings: settings)
                }
            }
        }
        .onChange(of: settings.cleanup) { _, _ in
            // Load the mode's model and prime the prompt-prefix cache now, server-side, so the
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

    /// `padding` drops to a hairline for the groups made of rows: a row that is the hit target has
    /// to reach the edges of its card, or the part of it you can click stops short of the part of
    /// it you can see.
    @ViewBuilder
    private func settingsGroup(_ title: String, padding: CGFloat = 16,
                               @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: padding < 10 ? 1 : 10) {
                content()
            }
            .card(padding: padding)
        }
    }

    @ViewBuilder
    private func permissionRow(_ name: String, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.red)
            Text(name)
                .font(.bj(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(hint)
                .font(.bj(12))
                .foregroundStyle(Theme.inkSubtle)
        }
    }
}

/// Label left, switch hard right, and the whole row is the target. The switch is a small thing to
/// aim at, and the row already says what it does — so the switch does not take the click at all
/// (`allowsHitTesting(false)`), which also rules out a click landing on both and cancelling itself.
struct ToggleRow: View {
    var themeID = Appearance.current
    let title: String
    let help: String
    @Binding var isOn: Bool

    init(_ title: String, help: String, isOn: Binding<Bool>) {
        self.title = title
        self.help = help
        self._isOn = isOn
    }

    var body: some View {
        Button { withAnimation(.bjSnap) { isOn.toggle() } } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.bj(13))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.blue)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// One of two ways to spend the pause between letting go and seeing text. The line beside the name
/// is not a subtitle — it is the entire content of the choice, since nothing about picking Fast or
/// Accurate is visible until you have already dictated something.
private struct ChoiceRow: View {
    var themeID = Appearance.current
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // A marker column, so the two names start at the same x and the eye reads down
                // the list rather than around a tick that moves the text.
                Image(systemName: "checkmark")
                    .font(.bj(10.5, weight: .bold))
                    .foregroundStyle(Theme.blue)
                    .frame(width: 12, alignment: .leading)
                    .opacity(selected ? 1 : 0)
                Text(title)
                    .font(.bj(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 68, alignment: .leading)
                Text(detail)
                    .font(.bj(12))
                    .foregroundStyle(Theme.inkSubtle)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.surfaceActive
                                   : Theme.surfaceActive.opacity(hovering ? 0.5 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}

/// A theme, shown as the thing it themes: the window at postage-stamp size — sidebar, nav, content
/// cards, and the recording pill — drawn entirely from the palette on offer.
///
/// It used to show a brand render on one card and a bare gradient on the other, which promised a
/// photograph and a blank page and delivered neither. Every fill here comes from the same table
/// the app reads at runtime, so a swatch cannot show a look the app will not draw.
struct ThemeSwatch: View {
    var themeID = Appearance.current
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// System draws both halves. It resolves to Light or Dark, so on its own it would be an exact
    /// copy of whichever one is in force — two identical cards and no way to tell which is which.
    /// Showing the pair is also the truer answer: what System means is "both, whichever applies".
    @ViewBuilder
    private var preview: some View {
        if appearance == .system {
            MiniWindow(palette: Appearance.light.palette)
                .overlay {
                    MiniWindow(palette: Appearance.dark.palette)
                        .mask { HStack(spacing: 0) { Color.clear; Color.black } }
                }
        } else {
            MiniWindow(palette: appearance.palette)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(height: 96)
                HStack(spacing: 6) {
                    Text(appearance.rawValue)
                        .font(.bj(12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                        .font(.bj(10.5, weight: .bold))
                        .foregroundStyle(Theme.blue)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cream))
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

/// The app, small. Same proportions and the same parts as the real window, including the way a
/// theme with brand imagery puts it at the foot of the sidebar and fades it into the rail.
private struct MiniWindow: View {
    var themeID = Appearance.current
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 58)
            content
        }
        .overlay(alignment: .bottom) {
            pill.padding(.bottom, 10)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            navRow(active: true, label: 26)
            navRow(active: false, label: 20)
            navRow(active: false, label: 23)
        }
        .padding(.horizontal, 5)
        .padding(.top, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                palette.surface
                if let name = palette.sidebarImage, let image = Theme.image(name) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 64)
                        .mask(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border.opacity(0.55)).frame(width: 1)
        }
    }

    private func navRow(active: Bool, label: CGFloat) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(active ? palette.blue : palette.inkTertiary.opacity(0.5))
                .frame(width: 4, height: 4)
            Capsule()
                .fill(active ? palette.blue : palette.inkTertiary.opacity(0.4))
                .frame(width: label, height: 3)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(active ? palette.surfaceActive : .clear))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(palette.ink.opacity(0.85)).frame(width: 44, height: 5)
            contentCard(line: 40, accent: true)
            contentCard(line: 30, accent: false)
        }
        .padding(.horizontal, 11)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.cream)
    }

    private func contentCard(line: CGFloat, accent: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(palette.ink.opacity(0.3)).frame(width: line, height: 3)
            if accent {
                Capsule().fill(palette.blue).frame(width: 11, height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.tableHeader))
    }

    /// The recording pill, the one part of the app that lives outside the window and the part a
    /// user recognises first — at the size and the place it actually draws.
    private var pill: some View {
        HStack(spacing: 2) {
            wave(4)
            wave(7)
            wave(5)
        }
        .frame(width: 46, height: 13)
        .background(Capsule().fill(palette.pillBackground))
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
    }

    private func wave(_ height: CGFloat) -> some View {
        Capsule().fill(palette.pillWave).frame(width: 1.5, height: height)
    }
}
