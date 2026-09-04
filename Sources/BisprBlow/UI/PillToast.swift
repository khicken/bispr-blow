import AppKit
import Combine
import SwiftUI

// MARK: - Toast

// Transient message above the pill: the mic that just changed, a paste fallback, a permission hint,
// a word just learned. Its own panel rather than a wider pill, so a long message never grows the
// pill's mouse footprint. Click-through while it is only information — it takes the mouse only when
// it carries a button, which so far is the learned-a-word Undo and nothing else.
final class ToastController {
    private let panel: NSPanel

    @MainActor
    init(controller: DictationController, model: PillModel) {
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

        let host = NSHostingView(rootView: ToastView(controller: controller, model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        actionObserver = controller.$noticeAction.sink { [weak self] action in
            self?.panel.ignoresMouseEvents = action == nil
        }

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
    private var actionObserver: AnyCancellable?

    // Sits against the pill wherever it is parked, so the two read as one thing: above it on the
    // bottom edge, and BESIDE it on a side edge. Above is what put the message halfway up an empty
    // screen, since a side-anchored pill is a tall bar at the vertical centre and the 420pt panel
    // then clamped to the screen edge. `ToastView` aligns its capsule to the same edge, so the
    // visible pill of text lands against the pill rather than 210pt away.
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
        let spot: NSPoint = switch anchor {
        case .bottomCentre: NSPoint(x: pill.midX - size.width / 2, y: pill.maxY + 4)
        case .leftCentre: NSPoint(x: pill.maxX + 4, y: pill.midY - size.height / 2)
        case .rightCentre: NSPoint(x: pill.minX - size.width - 4, y: pill.midY - size.height / 2)
        }
        panel.setFrameOrigin(NSPoint(
            x: min(max(spot.x, frame.minX), frame.maxX - size.width),
            y: min(max(spot.y, frame.minY), frame.maxY - size.height)
        ))
        panel.orderFrontRegardless()
    }
}

struct ToastView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var model: PillModel
    // Same reason as the pill: it draws the pill's background colour.
    @StateObject private var settings = AppSettings.shared

    // A notice is something the user needs; a mic change is something they might like to know.
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
                    if let action = controller.noticeAction {
                        Button(action.label) { action.run() }
                            .buttonStyle(.plain)
                            .font(.bj(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.22)))
                            .handCursor()
                    }
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
        // The capsule hugs the parked edge, so it lands against the pill rather than centred in a
        // 420pt panel whose edges nobody can see.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor.panelAlignment)
        .animation(.bjSoft, value: message)
    }
}
