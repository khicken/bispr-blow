import AppKit
import SwiftUI

/// The floating "flow bar": a small dark pill anchored bottom-center of the active screen.
/// Non-activating so the target app keeps focus. States: idle (tiny lozenge, expands on
/// hover with a hint), recording (waveform bars; stop button when hands-free), processing
/// (pulsing dots).
final class RecordingPillController {
    private let panel: NSPanel
    private let model: PillModel

    init(controller: DictationController, onOpenDashboard: @escaping (DashboardView.Section) -> Void) {
        model = PillModel(controller: controller, onOpenDashboard: onOpenDashboard)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        // Keep the pill pinned bottom-center of the active screen across display changes,
        // Space switches, and fullscreen/split-view transitions (which alter visibleFrame).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    private var repositionTimer: Timer?

    func reposition() {
        // Follow the screen the user is working on (keyboard focus), not the launch screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let target = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 6)
        if panel.frame.origin != target {
            panel.setFrameOrigin(target)
        }
        panel.orderFrontRegardless()
    }

    func setHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

// MARK: - View model

final class PillModel: ObservableObject {
    let controller: DictationController
    let onOpenDashboard: (DashboardView.Section) -> Void

    init(controller: DictationController, onOpenDashboard: @escaping (DashboardView.Section) -> Void) {
        self.controller = controller
        self.onOpenDashboard = onOpenDashboard
    }
}

// MARK: - SwiftUI pill

struct PillView: View {
    @ObservedObject var model: PillModel
    @ObservedObject var controller: DictationController
    @State private var hovering = false
    @State private var waveSamples: [Float] = Array(repeating: 0, count: PillView.barCount)

    static let barCount = 14

    init(model: PillModel) {
        self.model = model
        self.controller = model.controller
    }

    var body: some View {
        VStack {
            Spacer()
            pill
                .onHover { hovering = $0 }
                .contextMenu {
                    Button("Open Bluejay Wispr") { model.onOpenDashboard(.home) }
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: controller.state)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: hovering)
        .onReceive(controller.$level) { level in
            guard case .recording = controller.state else { return }
            waveSamples.removeFirst()
            waveSamples.append(level)
        }
    }

    @ViewBuilder
    private var pill: some View {
        Group {
            // Notices only replace the idle state — never the live waveform/processing UI.
            if controller.state == .idle, let notice = controller.notice {
                noticePill(notice)
            } else {
                switch controller.state {
                case .idle:
                    idlePill
                case .recording(let locked):
                    recordingPill(locked: locked)
                case .processing:
                    processingPill
                }
            }
        }
        .background(
            Capsule().fill(Theme.pillBackground)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        )
        .padding(.bottom, 4)
    }

    /// Idle: tiny sliver; on hover, Wispr-style circular action buttons.
    private var idlePill: some View {
        Group {
            if hovering {
                HStack(spacing: 7) {
                    PillCircleButton(help: "Dictate hands-free (or hold fn)") {
                        controller.startHandsFree()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    PillCircleButton(help: "Open Bluejay Wispr") {
                        model.onOpenDashboard(.home)
                    } label: {
                        if let logo = Theme.logo("Symbol_White") {
                            Image(nsImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 13, height: 13)
                        } else {
                            Image(systemName: "house.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    PillCircleButton(help: "Recent dictations") {
                        model.onOpenDashboard(.history)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 36)
            } else {
                Color.clear.frame(width: 42, height: 9)
            }
        }
        .contentShape(Capsule())
    }

    private func recordingPill(locked: Bool) -> some View {
        HStack(spacing: 8) {
            waveform
            if let flash = controller.micFlash, !flash.isEmpty {
                Text(flash)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                    .transition(.opacity)
            }
            if locked {
                Button {
                    controller.stopHandsFree()
                } label: {
                    ZStack {
                        Circle().fill(Theme.red).frame(width: 16, height: 16)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.white)
                            .frame(width: 6, height: 6)
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop and insert")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 28)
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(Theme.pillWave)
                    .frame(width: 2.5, height: CGFloat(3 + waveSamples[i] * 20))
                    .animation(.linear(duration: 0.08), value: waveSamples[i])
            }
        }
        .frame(height: 24)
    }

    private var processingPill: some View {
        ProcessingDots()
            .padding(.horizontal, 14)
            .frame(height: 22)
    }

    private func noticePill(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 24)
    }
}

/// Circular action button on the hover pill, with its own hover highlight.
struct PillCircleButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(hovering ? 0.28 : 0.14))
                label()
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// Three softly pulsing dots, Wispr-style "thinking" state.
struct ProcessingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.blue)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 0.25 : 1)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}
