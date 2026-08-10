import AppKit
import SwiftUI

/// The floating "flow bar": a small dark pill anchored bottom-center of the active screen.
/// Non-activating so the target app keeps focus. States: idle (tiny lozenge, expands on
/// hover with a hint), recording (waveform bars; stop button when hands-free), processing
/// (pulsing dots).
final class RecordingPillController {
    private let panel: NSPanel
    private let model: PillModel
    private let placement = PlacementModel()
    private var overlay: PlacementOverlayController?

    init(controller: DictationController, onOpenDashboard: @escaping (DashboardView.Section) -> Void) {
        model = PillModel(controller: controller, onOpenDashboard: onOpenDashboard)
        let saved = Anchor(rawValue: UserDefaults.standard.string(forKey: "pillAnchor") ?? "")
            ?? .bottomCentre
        model.anchor = saved

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PillView.size(for: .idle, anchor: saved)),
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
        overlay = PlacementOverlayController(model: placement)
        model.onDragChanged = { [weak self] point in self?.dragChanged(to: point) }
        model.onDragEnded = { [weak self] point in self?.dragEnded(at: point) }

        repositionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    private var repositionTimer: Timer?

    /// Where the user parked the pill. The bar is small and the Dock, the menu bar extras and
    /// whatever app is open all compete for the same edges, so this is a preference, not a
    /// constant — a bottom-centre bar sits on top of the middle of the Dock.
    enum Anchor: String, CaseIterable, Identifiable {
        case bottomCentre, leftCentre, rightCentre

        var id: String { rawValue }

        /// On a side edge the pill turns 90°, so its panel's width and height swap.
        var isVertical: Bool { self != .bottomCentre }

        /// How far to turn the pill's contents. The two edges turn opposite ways so the bar always
        /// leans away from the screen edge it is parked on.
        var rotation: Double {
            switch self {
            case .bottomCentre: 0
            case .leftCentre: -90
            case .rightCentre: 90
            }
        }

        /// Which edge of its own panel the bar sits against, in the panel's *unrotated* space.
        /// `rotation` then maps that onto the screen edge the pill is parked on: rotating clockwise
        /// sends the local top edge to the right and counter-clockwise sends it to the left, so both
        /// side anchors want `.top` and only the bottom anchor wants `.bottom`.
        ///
        /// This exists because the panel is always as big as the *expanded* row — it cannot be sized
        /// from hover state — so without it the resting sliver is centred in a box four times its
        /// size, floating off the bezel with nothing anchoring the expansion.
        var contentAlignment: Alignment {
            self == .bottomCentre ? .bottom : .top
        }

        /// Bottom-left origin for a panel of `size`, within the frame the pill lays out in.
        ///
        /// The inset keeps the side anchors off the bezel. It is small because the bar inside the
        /// panel now hugs the panel's own edge (see `contentAlignment`) and carries a 6pt shadow
        /// margin of its own, so the gap the user sees is this plus that.
        func origin(size: CGSize, in frame: CGRect, inset: CGFloat = 4) -> NSPoint {
            switch self {
            case .bottomCentre: NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
            case .leftCentre: NSPoint(x: frame.minX + inset, y: frame.midY - size.height / 2)
            case .rightCentre: NSPoint(x: frame.maxX - size.width - inset, y: frame.midY - size.height / 2)
            }
        }

        /// Exactly where the pill lands here, which is what the placeholder previews while placing —
        /// so the target the user sees is the shape they get, turned the way it will be turned.
        func landing(in frame: CGRect) -> CGRect {
            let size = PillView.size(for: .idle, anchor: self)
            return CGRect(origin: origin(size: size, in: frame), size: size)
        }

        /// The catch area around a landing spot. Generous, because the placeholder is only pill
        /// sized and nobody should have to aim at a 48pt target. The highlight is driven off this
        /// same rect, so a lit-up target always means a release will land there.
        func zone(in frame: CGRect) -> CGRect {
            landing(in: frame).insetBy(dx: -64, dy: -64)
        }

        /// The zone a point is inside, or nil. Deliberately not a nearest-match: releasing away
        /// from every target leaves the pill where it is rather than flinging it somewhere.
        static func containing(_ point: NSPoint, in frame: CGRect) -> Anchor? {
            allCases.first { $0.zone(in: frame).contains(point) }
        }
    }

    private var anchor: Anchor {
        get { Anchor(rawValue: UserDefaults.standard.string(forKey: "pillAnchor") ?? "") ?? .bottomCentre }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "pillAnchor")
            model.anchor = newValue  // the view rotates and transposes off this
        }
    }

    /// Dragging the pill picks a place for it. The screen dims, the three targets appear, and the
    /// pill itself is replaced by the Bluejay icon riding the cursor. The panel does not move: a
    /// window that follows the pointer has to be resized and repositioned mid-gesture, and every
    /// one of those moves rebuilds its tracking areas — which is what made the pill stutter and
    /// slip out from under the cursor when it did follow. The icon is drawn inside the overlay,
    /// which is already full-screen and click-through, so it costs no window of its own.
    private func dragChanged(to point: NSPoint) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = Self.layoutFrame(screen)
        placement.screen = frame
        placement.full = screen.frame
        placement.cursor = point
        placement.highlighted = Anchor.containing(point, in: frame)
        if !placement.placing {
            placement.placing = true
            overlay?.setVisible(true, on: screen)
            // Fade out rather than order out: the DragGesture is hosted in this window, so
            // ordering it out mid-drag stops event delivery and the drag ends on the spot.
            // A zero-alpha window still tracks the mouse.
            panel.alphaValue = 0
        }
    }

    private func dragEnded(at point: NSPoint) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        placement.placing = false
        placement.highlighted = nil
        placement.cursor = nil
        panel.alphaValue = 1
        overlay?.setVisible(false, on: screen)
        model.noteDragEnded()
        let frame = Self.layoutFrame(screen)
        guard let target = Anchor.containing(point, in: frame), target != anchor else { return }
        anchor = target
        // Size as well as origin: a side anchor turns the pill 90° and transposes its panel.
        let settled = PillView.size(for: .idle, anchor: target)
        panel.setFrame(NSRect(origin: target.origin(size: settled, in: frame), size: settled),
                       display: true, animate: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: settled)
    }

    /// Follow the pill's declared size so the panel never claims mouse events the pill cannot use.
    /// Called once per state transition, not per animation frame — see the note in `init`.
    private func resize(to size: CGSize) {
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        reposition()
    }

    /// The rect the pill is laid out inside.
    ///
    /// `visibleFrame` normally: it stops above the Dock, so the bar sits on the Dock's top edge
    /// rather than on top of the middle of it, eating clicks on the centre icons.
    ///
    /// But `visibleFrame` subtracts the Dock and menu bar from the *system configuration*, not from
    /// the current space. With a pinned Dock it keeps reserving that strip even in a fullscreen
    /// space where the Dock is hidden and nothing is there — which is why the bar floated a Dock's
    /// height off the bottom of every fullscreen app instead of dropping to the edge. There is
    /// something to detect after all.
    static func layoutFrame(_ screen: NSScreen) -> CGRect {
        isFullScreen(screen) ? screen.frame : screen.visibleFrame
    }

    /// Whether an ordinary window is covering a strip that `visibleFrame` is still reserving, which
    /// is the actual question: if something is drawn over the Dock's strip then the Dock is not
    /// there and the pill should drop past it.
    ///
    /// Measured against `visibleFrame`, not the full screen. Matching the full screen exactly was
    /// the obvious test and it never fired: on a notched display a fullscreen window gets the area
    /// *below* the camera, so it is a menu bar's height shorter than the screen. A merely zoomed
    /// window is exactly `visibleFrame` tall, so "taller than visibleFrame" separates the two
    /// cleanly whether or not there is a notch, and whether the Dock is pinned or on a side.
    ///
    /// When the Dock is hidden this can fail to fire on a notched display — and it does not matter
    /// there, because `visibleFrame` already reaches the bottom of the screen.
    ///
    /// Window *names* need Screen Recording permission; geometry does not, so this stays a metadata
    /// read. Our own panels sit above layer 0 and are never counted.
    private static func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let visible = screen.visibleFrame
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return false }
            return height > visible.height + 1 && width >= visible.width - 1
        }
    }

    private var lastLayoutFrame: CGRect?

    func reposition() {
        // Follow the screen the user is working on (keyboard focus), not the launch screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = Self.layoutFrame(screen)
        // Logged on change only, because getting this wrong is invisible from the code: it depends
        // on the Dock's setting, whether the display has a notch, and what the frontmost app does
        // in fullscreen. If the bar is at the wrong height, this line says which frame it chose.
        if frame != lastLayoutFrame {
            lastLayoutFrame = frame
            logLine("layout frame=\(frame.debugDescription) screen=\(screen.frame.debugDescription) "
                    + "visible=\(screen.visibleFrame.debugDescription)")
        }
        let size = panel.frame.size
        let target = anchor.origin(size: size, in: frame)
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
    /// Which edge the pill is parked on. Drives the 90° turn on the side anchors.
    @Published var anchor: RecordingPillController.Anchor = .bottomCentre
    /// Screen coordinates of the pointer while dragging the pill to a new place.
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    init(controller: DictationController, onOpenDashboard: @escaping (DashboardView.Section) -> Void) {
        self.controller = controller
        self.onOpenDashboard = onOpenDashboard
    }

    private var dragEndedAt = Date.distantPast

    func noteDragEnded() { dragEndedAt = Date() }

    /// Every pill button goes through here. The drag is a `simultaneousGesture` so the buttons keep
    /// working, which means a release back over the pill's own frame lands on whichever button is
    /// under the cursor — a synthetic drag test started a real hands-free dictation that recorded
    /// until the app was killed. SwiftUI delivers the tap after the gesture ends, so the guard is a
    /// short window rather than a flag cleared on release.
    func tapped(_ action: () -> Void) {
        guard Date().timeIntervalSince(dragEndedAt) > 0.25 else { return }
        action()
    }
}

// MARK: - SwiftUI pill

struct PillView: View {
    @ObservedObject var model: PillModel
    @ObservedObject var controller: DictationController
    /// Observed, not just read: the pill draws `Theme` colours and shows the user's own shortcut
    /// name, and without this it keeps whichever theme and binding it was built with until relaunch.
    @StateObject private var settings = AppSettings.shared
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

    /// The panel size for a state on a given edge. A side-anchored pill is the same bar turned 90°,
    /// so the panel is the transpose — the layout below never changes, only its orientation.
    static func size(for state: DictationController.State,
                     anchor: RecordingPillController.Anchor) -> CGSize {
        let flat = size(for: state)
        return anchor.isVertical ? CGSize(width: flat.height, height: flat.width) : flat
    }

    /// Room for the capsule's shadow to fade out. Every point of it is also panel, and therefore
    /// dead to the app underneath, so it stays as small as the shadow allows.
    private static let margin: CGFloat = 6

    private var targetSize: CGSize { Self.size(for: controller.state, anchor: model.anchor) }

    var body: some View {
        pill
            // Animations sit *below* the frame on purpose, so they move the capsule and not the
            // hit region. The hit region has to be the panel rect exactly: the panel jumps
            // straight to its target size, so anything that interpolates alongside it slides the
            // hover region out from under a stationary pointer and the pill flaps open and shut.
            // `targetSize` only grows around the same bottom-centre anchor, so a pointer inside
            // the collapsed rect is always inside the expanded one.
            .animation(Self.grow, value: controller.state)
            // Rotation keeps the unrotated layout size, so the transposed frame below is exactly
            // what the turned bar occupies, and the panel matches it.
            .rotationEffect(.degrees(model.anchor.rotation))
            .frame(width: targetSize.width, height: targetSize.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // `simultaneousGesture` so the hover buttons keep working: a real click never travels
            // far enough to start this, and a drag that does never lands on a button.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in model.onDragChanged?(NSEvent.mouseLocation) }
                    .onEnded { _ in model.onDragEnded?(NSEvent.mouseLocation) }
            )
            .contextMenu {
                Button("Open Bluejay Wispr") { model.onOpenDashboard(.home) }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .onChange(of: targetSize, initial: true) { _, size in
                model.onSize?(size)
                // The panel is now the recording bar's size — the frame the reveal animates from.
                if case .recording = controller.state { ActivationTrace.mark("pill") }
            }
            .onReceive(controller.$level) { level in
                guard case .recording = controller.state else { return }
                waveSamples.removeFirst()
                waveSamples.append(level)
            }
    }

    static let grow = Animation.spring(response: 0.32, dampingFraction: 0.82)

    @ViewBuilder
    private var pill: some View {
        Group {
            switch controller.state {
            case .idle:
                idlePill
            case .recording(let locked):
                capsule(recordingPill(locked: locked))
            case .processing:
                capsule(processingPill)
            }
        }
        .padding(Self.margin)
    }

    /// The dark capsule a state sits on. Applied to whatever actually carries that state's size,
    /// rather than wrapped around the whole pill: for idle the capsule is the thing that grows, and
    /// a background around a fixed-size parent would just draw it full size the whole time.
    private func capsule(_ content: some View) -> some View {
        content.background(
            Capsule().fill(Theme.pillBackground)
                // Fits inside `margin`. A shadow wider than the panel gets clipped by the window
                // edge, and a clipped gaussian reads as a translucent rectangle around the pill.
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        )
    }

    /// Idle: a sliver on the parked edge that grows into three circular action buttons on hover.
    ///
    /// Exactly one thing animates — the capsule's own frame — and it is pinned to the edge the pill
    /// is parked on, so the expansion has a single fixed anchor. Everything else is a constant: the
    /// outer box is always the expanded size, and the buttons are centred in *that*, so they fade in
    /// where they will end up rather than travelling with a capsule that is still growing.
    ///
    /// The animation modifier stays inside the outer frame. Outside it, the fixed box interpolates
    /// too, and a hit region that slides under a stationary pointer makes the pill flap open and
    /// shut.
    private var idlePill: some View {
        capsule(
            Color.clear.frame(width: hovering ? 110 : 42, height: hovering ? 36 : 9)
        )
        .animation(Self.grow, value: hovering)
        .frame(width: 110, height: 36, alignment: model.anchor.contentAlignment)
        .overlay {
            hoverButtons
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.86)
                .animation(Self.grow, value: hovering)
                .allowsHitTesting(hovering)
        }
        .contentShape(Capsule())
    }

    /// The glyphs counter-rotate: the bar turns 90° on a side edge, but an icon lying on its side
    /// is just wrong to look at — a side Dock does not rotate its icons either. The capsule and
    /// the waveform still turn with the bar, which is what should turn.
    private var hoverButtons: some View {
        let upright = -model.anchor.rotation
        return HStack(spacing: 7) {
            PillCircleButton(help: AppSettings.shared.holdPhrase
                .map { "Dictate hands-free (or \($0.prefix(1).lowercased() + $0.dropFirst()))" }
                ?? "Dictate hands-free", counterRotation: upright) {
                model.tapped { controller.startHandsFree() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.bj(11, weight: .medium))
                    .foregroundStyle(.white)
            }
            PillCircleButton(help: "Open Bluejay Wispr", counterRotation: upright) {
                model.tapped { model.onOpenDashboard(.home) }
            } label: {
                if let logo = Theme.logo("Symbol_White") {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "house.fill")
                        .font(.bj(11, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            PillCircleButton(help: "Recent dictations", counterRotation: upright) {
                model.tapped { model.onOpenDashboard(.history) }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.bj(11, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 9)
        // The `.idle` row in `size(for:)`. Explicit, so the overlay keeps its natural size instead
        // of being squashed into the 42x9 sliver on the way in.
        .frame(width: 110, height: 36)
    }

    private func recordingPill(locked: Bool) -> some View {
        HStack(spacing: 8) {
            waveform
            if locked {
                Button {
                    model.tapped { controller.stopHandsFree() }
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

// MARK: - Placement

final class PlacementModel: ObservableObject {
    @Published var placing = false
    @Published var highlighted: RecordingPillController.Anchor?
    /// The visible frame the targets were computed against.
    @Published var screen: CGRect = .zero
    /// The whole screen — the overlay panel's own frame, and therefore what screen coordinates
    /// are mapped against.
    @Published var full: CGRect = .zero
    /// Pointer position while placing; the icon proxy rides it. nil when not placing.
    @Published var cursor: NSPoint?
}

/// Dims the screen and shows where the pill can go while the user drags it. Click-through, like
/// the toast: it is a picture of the choice, and the drag it belongs to is already being tracked
/// by the pill. A full-screen panel that accepted mouse events would swallow the whole screen.
final class PlacementOverlayController {
    private let panel: NSPanel

    init(model: PlacementModel) {
        panel = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Just under the pill, so the pill stays visible above the dim rather than being buried.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PlacementView(model: model))
    }

    func setVisible(_ visible: Bool, on screen: NSScreen) {
        guard visible else { return panel.orderOut(nil) }
        panel.setFrame(screen.frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.orderFrontRegardless()
    }
}

struct PlacementView: View {
    @ObservedObject var model: PlacementModel

    /// Icon proxy size. Big enough to read as the pill's stand-in, small enough not to cover the
    /// target it is being dropped on.
    private static let proxySize: CGFloat = 40

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(model.placing ? 0.34 : 0)
            if model.placing {
                ForEach(RecordingPillController.Anchor.allCases) { anchor in
                    target(anchor)
                }
                if let cursor = model.cursor {
                    proxy(at: cursor)
                }
            }
        }
        .animation(.bjSoft, value: model.placing)
        .animation(.bjHover, value: model.highlighted)
        .ignoresSafeArea()
    }

    /// Screen coordinates are bottom-left, the view's are top-left, and both are measured against
    /// the overlay panel's own frame — the whole screen. Flipping against the view's measured
    /// height instead double-counts the Dock, because the targets are laid out inside
    /// `visibleFrame` and this panel is not.
    private func point(_ screenPoint: NSPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - model.full.minX, y: model.full.maxY - screenPoint.y)
    }

    /// The pill, in transit. The real one is faded out for the duration of the drag, so this is
    /// the only thing under the cursor and the placeholder targets stay legible.
    private func proxy(at cursor: NSPoint) -> some View {
        let centre = point(cursor)
        return LogoView(name: "Symbol_White", size: Self.proxySize)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            .offset(x: centre.x - Self.proxySize / 2, y: centre.y - Self.proxySize / 2)
    }

    @ViewBuilder
    private func target(_ anchor: RecordingPillController.Anchor) -> some View {
        let lit = model.highlighted == anchor
        let landing = anchor.landing(in: model.screen)
        let topLeft = point(NSPoint(x: landing.minX, y: landing.maxY))
        let x = topLeft.x
        let y = topLeft.y

        RoundedRectangle(cornerRadius: min(landing.width, landing.height) / 2.2)
            .fill(.white.opacity(lit ? 0.95 : 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: min(landing.width, landing.height) / 2.2)
                    .stroke(.white.opacity(lit ? 0 : 0.5), lineWidth: 1)
            )
            .frame(width: landing.width, height: landing.height)
            .scaleEffect(lit ? 1.08 : 1)
            .shadow(color: .black.opacity(lit ? 0.25 : 0), radius: 8, y: 2)
            .offset(x: x, y: y)
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
        // The same frame the pill uses, or the toast detaches from it in a fullscreen space.
        let frame = RecordingPillController.layoutFrame(screen)
        let size = panel.frame.size
        let anchor = RecordingPillController.Anchor(
            rawValue: UserDefaults.standard.string(forKey: "pillAnchor") ?? ""
        ) ?? .bottomCentre
        let pillSize = PillView.size(for: .idle, anchor: anchor)
        let pill = NSRect(origin: anchor.origin(size: pillSize, in: frame), size: pillSize)
        let x = min(max(pill.midX - size.width / 2, frame.minX), frame.maxX - size.width)
        let y = min(pill.maxY + 4, frame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}

struct ToastView: View {
    @ObservedObject var controller: DictationController
    /// Same reason as the pill: it draws the pill's background colour.
    @StateObject private var settings = AppSettings.shared

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
                            .font(.bj(9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(message)
                        .font(.bj(11, weight: .medium))
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
    /// Turned back upright when the bar itself is rotated onto a side edge.
    var counterRotation: Double = 0
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(hovering ? 0.28 : 0.14))
                label().rotationEffect(.degrees(counterRotation))
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
    var themeID = Appearance.current
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
