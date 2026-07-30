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
            contentRect: NSRect(origin: .zero, size: PillView.size(for: .idle)),
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

        // The panel must be exactly as big as the pill draws. A borderless panel claims every
        // point in its frame at the window-server level, and SwiftUI declining the hit does not
        // hand the click back to the app underneath — it is simply swallowed. A fixed 360x56
        // panel around a 42x9 sliver therefore left a dead band across the bottom of the screen.
        //
        // The size comes from the pill's discrete state, never from a measured geometry: driving
        // it from `onGeometryChange` fired on every frame of the spring, and resizing a window
        // 60 times a second thrashes its tracking areas and cursor rects. That stuttered the
        // cursor and, when a spurious mouse-exit landed mid-animation, collapsed the pill out
        // from under the pointer.
        model.onSize = { [weak self] size in self?.resize(to: size) }

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

    /// Follow the pill's declared size so the panel never claims mouse events the pill cannot use.
    /// Called once per state transition, not per animation frame — see the note in `init`.
    private func resize(to size: CGSize) {
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        reposition()
    }

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
    /// Reports the pill's drawn size so the panel can shrink to it.
    var onSize: ((CGSize) -> Void)?

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

    /// Panel size per state. These are the layout numbers below plus `margin` on every side, and
    /// they have to stay in step with them: the panel is sized from here, so content that outgrows
    /// its entry gets clipped. Kept as a table rather than measured, because measuring an animating
    /// view resizes the window on every frame.
    ///
    /// Deliberately not a function of `hovering`. Resizing a window tears down and rebuilds its
    /// tracking areas, and the rebuild emits a spurious `mouseExited` with no matching enter until
    /// the pointer moves again — so a hover-sized panel collapses under a stationary cursor and
    /// stutters under a moving one. The idle panel is therefore always big enough for the hover
    /// row, and hovering changes only what is drawn inside it. The cost is that the idle pill's
    /// mouse footprint is the hover target rather than the visible sliver; the sliver alone is
    /// too small to aim at anyway.
    static func size(for state: DictationController.State) -> CGSize {
        let content: CGSize = switch state {
        case .idle:
            // 3 × 26pt circles + 2 × 7pt spacing + 9pt padding each side.
            CGSize(width: 110, height: 36)
        case .recording(let locked):
            // 14 bars × 2.5pt + 13 × 2.5pt spacing + 13pt padding each side, plus the stop button.
            CGSize(width: locked ? 125.5 : 93.5, height: 28)
        case .processing:
            // 3 × 6pt dots + 2 × 5pt spacing + 14pt padding each side.
            CGSize(width: 56, height: 22)
        }
        return CGSize(width: (content.width + margin * 2).rounded(.up),
                      height: (content.height + margin * 2).rounded(.up))
    }

    /// Room for the capsule's shadow to fade out. Every point of it is also panel, and therefore
    /// dead to the app underneath, so it stays as small as the shadow allows.
    private static let margin: CGFloat = 6

    private var targetSize: CGSize { Self.size(for: controller.state) }

    var body: some View {
        pill
            // Animations sit *below* the frame on purpose, so they move the capsule and not the
            // hit region. The hit region has to be the panel rect exactly: the panel jumps
            // straight to its target size, so anything that interpolates alongside it slides the
            // hover region out from under a stationary pointer and the pill flaps open and shut.
            // `targetSize` only grows around the same bottom-centre anchor, so a pointer inside
            // the collapsed rect is always inside the expanded one.
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: controller.state)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: hovering)
            .frame(width: targetSize.width, height: targetSize.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Open Bluejay Wispr") { model.onOpenDashboard(.home) }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .onChange(of: targetSize, initial: true) { _, size in model.onSize?(size) }
            .onReceive(controller.$level) { level in
                guard case .recording = controller.state else { return }
                waveSamples.removeFirst()
                waveSamples.append(level)
            }
    }

    @ViewBuilder
    private var pill: some View {
        Group {
            switch controller.state {
            case .idle:
                idlePill
            case .recording(let locked):
                recordingPill(locked: locked)
            case .processing:
                processingPill
            }
        }
        .background(
            Capsule().fill(Theme.pillBackground)
                // Fits inside `margin`. A shadow wider than the panel gets clipped by the window
                // edge, and a clipped gaussian reads as a translucent rectangle around the pill.
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        )
        .padding(Self.margin)
    }

    /// Idle: tiny sliver; on hover, Wispr-style circular action buttons.
    private var idlePill: some View {
        Group {
            if hovering {
                HStack(spacing: 7) {
                    PillCircleButton(help: AppSettings.shared.holdPhrase
                        .map { "Dictate hands-free (or \($0.prefix(1).lowercased() + $0.dropFirst()))" }
                        ?? "Dictate hands-free") {
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

}

// MARK: - Toast

/// Transient message above the pill: the mic that just changed, a paste fallback, a permission
/// hint. Its own panel rather than a wider pill, so a long message never grows the pill's mouse
/// footprint, and click-through because it is information the user reads, never a control.
final class ToastController {
    private let panel: NSPanel

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: ToastView(controller: controller))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

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
    }

    /// Clears the tallest pill state, so the toast never overlaps the waveform.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 62))
        panel.orderFrontRegardless()
    }
}

struct ToastView: View {
    @ObservedObject var controller: DictationController

    /// A notice is something the user needs; a mic change is something they might like to know.
    private var message: String? {
        if let notice = controller.notice, !notice.isEmpty { return notice }
        if let mic = controller.micFlash, !mic.isEmpty { return mic }
        return nil
    }

    var body: some View {
        VStack {
            if let message {
                HStack(spacing: 6) {
                    if controller.notice == nil {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    Capsule().fill(Theme.pillBackground)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                )
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.bjSoft, value: message)
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
