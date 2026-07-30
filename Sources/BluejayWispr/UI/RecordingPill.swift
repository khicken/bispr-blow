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
        panel.isMovableByWindowBackground = true
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
        // Drag to move it. The bar is draggable by its background, and snaps to the nearest
        // bottom anchor when released — free positioning would drift with every display change,
        // and the 2s re-pin below would undo it anyway.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            self?.panelMoved()
        }
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    private var repositionTimer: Timer?
    private var settleTimer: Timer?
    /// True while the user is dragging, so the re-pin timer does not fight their pointer.
    private var dragging = false
    /// True while `reposition` is moving the panel, so our own move does not read as a drag.
    private var movingProgrammatically = false

    /// Where the user parked the pill. The bar is small and the Dock, the menu bar extras and
    /// whatever app is open all compete for the same edges, so this is a preference, not a
    /// constant — a bottom-centre bar sits on top of the middle of the Dock.
    enum Anchor: String, CaseIterable {
        case bottomCentre, leftCentre, rightCentre

        /// Bottom-left origin for a panel of `size`. The side anchors sit vertically centred, so
        /// the pill clears the Dock and the menu bar entirely; the inset keeps it off the bezel.
        func origin(size: CGSize, in frame: CGRect, inset: CGFloat = 12) -> NSPoint {
            switch self {
            case .bottomCentre: NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
            case .leftCentre: NSPoint(x: frame.minX + inset, y: frame.midY - size.height / 2)
            case .rightCentre: NSPoint(x: frame.maxX - size.width - inset, y: frame.midY - size.height / 2)
            }
        }

        /// Anchor whose resting place is closest to where the pill was dropped. Distance between
        /// centres, in both axes — snapping on x alone is what made a vertical drag teleport back
        /// to the bottom of the screen.
        static func nearest(to centre: NSPoint, size: CGSize, in frame: CGRect) -> Anchor {
            allCases.min { a, b in
                func distance(_ anchor: Anchor) -> CGFloat {
                    let o = anchor.origin(size: size, in: frame)
                    let c = NSPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)
                    return hypot(c.x - centre.x, c.y - centre.y)
                }
                return distance(a) < distance(b)
            } ?? .bottomCentre
        }
    }

    private var anchor: Anchor {
        get { Anchor(rawValue: UserDefaults.standard.string(forKey: "pillAnchor") ?? "") ?? .bottomCentre }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pillAnchor") }
    }

    /// Called on every frame of a user drag. Snap to the nearest anchor once they stop.
    private func panelMoved() {
        guard !movingProgrammatically else { return }
        dragging = true
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let dropped = self.panel.frame
            self.anchor = Anchor.nearest(to: NSPoint(x: dropped.midX, y: dropped.midY),
                                        size: dropped.size, in: screen.frame)
            self.dragging = false
            // Glide to the anchor rather than cutting to it — an instant jump from wherever the
            // pointer let go reads as the pill teleporting.
            let target = self.anchor.origin(size: dropped.size, in: screen.frame)
            self.movingProgrammatically = true
            self.panel.setFrame(NSRect(origin: target, size: dropped.size), display: true, animate: true)
            self.movingProgrammatically = false
        }
    }

    /// Follow the pill's declared size so the panel never claims mouse events the pill cannot use.
    /// Called once per state transition, not per animation frame — see the note in `init`.
    private func resize(to size: CGSize) {
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        reposition()
    }

    func reposition() {
        // Never fight the user's pointer mid-drag.
        guard !dragging else { return }
        // Follow the screen the user is working on (keyboard focus), not the launch screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // `frame`, not `visibleFrame`: visibleFrame stops above the Dock, which parked the pill
        // ~80pt up the screen and in the middle of whatever the user was reading. The bar belongs
        // on the bottom edge. The panel's own `margin` supplies the small gap, so no offset here.
        let frame = screen.frame
        let size = panel.frame.size
        let target = anchor.origin(size: size, in: frame)
        if panel.frame.origin != target {
            movingProgrammatically = true
            panel.setFrameOrigin(target)
            movingProgrammatically = false
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
        // Same 2s re-pin as the pill, so the toast follows it after a drag.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    private var timer: Timer?

    /// Sits directly above the pill wherever the user parked it, so the two read as one thing.
    /// Clamped to the screen, because a 420pt toast centred on an edge-anchored pill would
    /// otherwise hang off the side.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let size = panel.frame.size
        let pillSize = PillView.size(for: .idle)
        let anchor = RecordingPillController.Anchor(
            rawValue: UserDefaults.standard.string(forKey: "pillAnchor") ?? ""
        ) ?? .bottomCentre
        let pill = NSRect(origin: anchor.origin(size: pillSize, in: frame), size: pillSize)
        let x = min(max(pill.midX - size.width / 2, frame.minX), frame.maxX - size.width)
        let y = min(pill.maxY + 4, frame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
