import AppKit
import Combine
import SwiftUI

// MARK: - Placement

final class PlacementModel: ObservableObject {
    @Published var placing = false
    @Published var highlighted: RecordingPillController.Anchor?
    // The visible frame the targets were computed against.
    @Published var screen: CGRect = .zero
    // The whole screen — the overlay panel's own frame, and what screen coordinates map against.
    @Published var full: CGRect = .zero
    // Pointer position while placing; the icon proxy rides it. nil when not placing.
    @Published var cursor: NSPoint?
}

// Dims the screen and shows where the pill can go while the user drags it. Click-through, like the
// toast: the drag it belongs to is already tracked by the pill, and a full-screen panel that
// accepted mouse events would swallow the whole screen.
final class PlacementOverlayController {
    private let panel: NSPanel

    init(model: PlacementModel) {
        panel = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Just under the pill, so the pill stays visible above the dim.
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

    // Icon proxy size: big enough to read as the pill's stand-in, small enough not to cover the
    // target it is dropped on.
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

    // Screen coordinates are bottom-left, the view's top-left, and both are measured against the
    // overlay panel's frame — the whole screen. Flipping against the view's measured height instead
    // double-counts the Dock, because the targets lay out inside `visibleFrame` and this panel does
    // not.
    private func point(_ screenPoint: NSPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - model.full.minX, y: model.full.maxY - screenPoint.y)
    }

    // The pill, in transit. The real one is faded out for the drag, so this is the only thing under
    // the cursor.
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
