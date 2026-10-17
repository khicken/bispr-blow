import AppKit
import SwiftUI

// Numbered badges over the few things Jay could not choose between, so the user can say the number.
// One tiny click-through panel per badge rather than a full-screen overlay: nothing else on screen
// stops taking clicks while they show.
@MainActor
enum JayLabels {
    static let badgeSize: CGFloat = 22
    static let badgeFontSize: CGFloat = 13

    private static var panels: [NSPanel] = []

    static func show(_ frames: [CGRect?]) {
        hide()
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else { return }
        for (index, frame) in frames.enumerated() {
            guard let frame else { continue }
            panels.append(makeBadge(number: index + 1, over: cocoaRect(fromAX: frame, primaryScreenHeight: primaryScreenHeight)))
        }
    }

    static func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    // AX frames are top-left origin on the primary screen; AppKit's are bottom-left.
    nonisolated static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    private static func makeBadge(number: Int, over element: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: element.minX, y: element.maxY - badgeSize, width: badgeSize, height: badgeSize),
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
        panel.contentView = NSHostingView(rootView: JayBadge(number: number))
        panel.orderFrontRegardless()
        return panel
    }
}

private struct JayBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.bj(JayLabels.badgeFontSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: JayLabels.badgeSize, height: JayLabels.badgeSize)
            .background(Circle().fill(Theme.blue))
    }
}
