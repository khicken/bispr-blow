import AppKit
import Combine
import SwiftUI

// The floating "flow bar": a small dark pill anchored to an edge of the active screen.
// Non-activating so the target app keeps focus. States: idle (tiny lozenge, expands on hover with a
// hint), recording (waveform bars; stop button when hands-free), processing (pulsing dots).
final class RecordingPillController {
    // Readable so `--pill-demo` can measure the composited window rather than the layout.
    let panel: NSPanel
    // Shared with the toast, which sits against the same edge the pill is parked on.
    let model: PillModel
    private let placement = PlacementModel()
    private var overlay: PlacementOverlayController?

    @MainActor
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

        // The panel must be exactly as big as the pill draws: a borderless panel swallows every
        // click in its frame at the window-server level, so a fixed 360x56 panel around a 42x9
        // sliver left a dead band across the bottom of the screen. The size comes from the discrete
        // state, never from measured geometry — driving it from `onGeometryChange` resized the
        // window on every spring frame, thrashing its tracking areas and collapsing the pill out
        // from under the pointer.
        model.onSize = { [weak self] size in self?.resize(to: size) }

        let host = NSHostingView(rootView: PillView(model: model))
        // The panel's size is `resize`'s alone. By default the hosting view pushes SwiftUI's ideal
        // size onto the window as content min/max and AppKit applies it the instant the state
        // changes, keeping the TOP-LEFT corner and skipping the `reposition()` a deliberate resize
        // carries. Measured on `leftCentre` with `--pill-demo`: the panel went 106pt to 68pt in
        // 10ms with its top edge pinned, carrying the pill 22pt up, then 19pt back down when the
        // deferred shrink ran 400ms later. That is the "jumps up and then goes back down".
        host.sizingOptions = []
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        // Keep the pill pinned across display changes, Space switches, and fullscreen/split-view
        // transitions (which alter visibleFrame).
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

        // Hiding the idle pill is a visibility setting, not a state: it still has to appear the
        // moment a dictation starts. Both inputs drive it, and idle is the only state that hides.
        Publishers.CombineLatest(controller.$state, AppSettings.shared.$alwaysShowPill)
            .sink { [weak self] state, always in
                self?.setHidden(!always && state == .idle)
            }
            .store(in: &visibility)
    }

    private var repositionTimer: Timer?
    private var visibility = Set<AnyCancellable>()
    private var isHidden = false

    // Where the user parked the pill. The Dock, the menu bar extras and the frontmost app compete
    // for the same edges, so this is a preference rather than a constant.
    enum Anchor: String, CaseIterable, Identifiable {
        case bottomCentre, leftCentre, rightCentre

        var id: String { rawValue }

        // On a side edge the pill turns 90°, so its panel's width and height swap.
        var isVertical: Bool { self != .bottomCentre }

        // How far to turn the pill's contents. The two edges turn opposite ways so the bar always
        // leans away from the screen edge it is parked on.
        var rotation: Double {
            switch self {
            case .bottomCentre: 0
            case .leftCentre: -90
            case .rightCentre: 90
            }
        }

        // Which edge of its own panel the bar sits against, in the panel's UNROTATED space;
        // `rotation` maps that onto the parked screen edge, so both side anchors want `.top` and
        // only the bottom anchor wants `.bottom`. It exists because the panel is always as big as
        // the expanded row, so without it the resting sliver floats centred in a box four times its
        // size.
        var contentAlignment: Alignment {
            self == .bottomCentre ? .bottom : .top
        }

        // The same parked edge in screen space: the edge `origin(size:in:)` pins. For the toast,
        // which is not rotated. NOT for anything inside `PillView` — the pill's frame sits after a
        // `rotationEffect`, which leaves the child's layout size unrotated, so on a side anchor that
        // frame is the transpose of its child and only centring lands the turned bar on the panel.
        // Using this there moved the pill 37pt off itself.
        var panelAlignment: Alignment {
            switch self {
            case .bottomCentre: .bottom
            case .leftCentre: .leading
            case .rightCentre: .trailing
            }
        }

        // Bottom-left origin for a panel of `size`, within the frame the pill lays out in. The
        // inset keeps the side anchors off the bezel, and is small because the bar hugs the panel's
        // own edge (see `contentAlignment`) and carries a 6pt shadow margin of its own.
        func origin(size: CGSize, in frame: CGRect, inset: CGFloat = 4) -> NSPoint {
            switch self {
            case .bottomCentre: NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
            case .leftCentre: NSPoint(x: frame.minX + inset, y: frame.midY - size.height / 2)
            case .rightCentre: NSPoint(x: frame.maxX - size.width - inset, y: frame.midY - size.height / 2)
            }
        }

        // Exactly where the pill lands here, so the target the user sees while placing is the shape
        // they get, turned the way it will be turned.
        func landing(in frame: CGRect) -> CGRect {
            let size = PillView.size(for: .idle, anchor: self)
            return CGRect(origin: origin(size: size, in: frame), size: size)
        }

        // The catch area around a landing spot. Generous, because the placeholder is only pill
        // sized. The highlight is driven off this same rect, so a lit target always means a hit.
        func zone(in frame: CGRect) -> CGRect {
            landing(in: frame).insetBy(dx: -64, dy: -64)
        }

        // The zone a point is inside, or nil. Deliberately not a nearest-match: releasing away from
        // every target leaves the pill where it is.
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

    // Dragging the pill picks a place for it: the screen dims, three targets appear, and the pill is
    // replaced by an icon riding the cursor. The panel does not move — a window that follows the
    // pointer is resized and repositioned mid-gesture, rebuilding its tracking areas, which is what
    // made the pill stutter and slip out from under the cursor. The icon is drawn inside the
    // full-screen click-through overlay, so it costs no window of its own.
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
            // Fade out rather than order out: the DragGesture is hosted in this window, so ordering
            // it out mid-drag ends the drag on the spot. A zero-alpha window still tracks the mouse.
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

    // Follow the pill's declared size so the panel never claims mouse events the pill cannot use.
    // Called once per state transition, not per animation frame — see the note in `init`.
    //
    // Grows immediately, shrinks only once the morph has settled: a borderless panel hard-clips, and
    // the capsule spends the whole 0.32s spring at the OUTGOING state's size, so shrinking up front
    // cut 13pt off each end of the bar still on screen (25pt for the hands-free bar), on release.
    private func resize(to size: CGSize) {
        pendingSize = size
        guard panel.frame.size != size else { return }
        guard size.width > panel.frame.width || size.height > panel.frame.height else {
            DispatchQueue.main.asyncAfter(deadline: .now() + PillView.growSettled) { [weak self] in
                // Stale if another state landed in the meantime; that transition owns the size now.
                guard let self, pendingSize == size else { return }
                apply(size)
            }
            return
        }
        apply(size)
    }

    private var pendingSize: CGSize?

    private func apply(_ size: CGSize) {
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        reposition()
    }

    // The rect the pill is laid out inside. `visibleFrame` normally, so the bar sits on the Dock's
    // top edge rather than eating clicks on its centre icons. But `visibleFrame` subtracts the Dock
    // and menu bar from the SYSTEM configuration, not from the current space, so with a pinned Dock
    // it keeps reserving that strip in a fullscreen space where nothing is there — which floated the
    // bar a Dock's height off the bottom of every fullscreen app.
    static func layoutFrame(_ screen: NSScreen) -> CGRect {
        isFullScreen(screen) ? screen.frame : screen.visibleFrame
    }

    // Whether an ordinary window covers a strip `visibleFrame` is still reserving: if something is
    // drawn over the Dock's strip then the Dock is not there and the pill should drop past it.
    //
    // Measured against `visibleFrame`, not the full screen. Matching the full screen never fired: on
    // a notched display a fullscreen window gets the area BELOW the camera, so it is a menu bar
    // shorter than the screen, while a merely zoomed window is exactly `visibleFrame` tall. With the
    // Dock hidden this can fail to fire on a notched display, and it does not matter there because
    // `visibleFrame` already reaches the bottom. Window names would need Screen Recording
    // permission; geometry does not. Our own panels sit above layer 0 and are never counted.
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
        // Logged on change only: the right frame depends on the Dock's setting, the notch, and what
        // the frontmost app does in fullscreen, so this line says which frame it chose.
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
        // The 2s reposition timer runs whether or not the pill is meant to be on screen, so without
        // this it would order a hidden pill straight back to the front.
        if !isHidden { panel.orderFrontRegardless() }
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}
