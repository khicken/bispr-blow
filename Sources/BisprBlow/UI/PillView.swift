import AppKit
import Combine
import SwiftUI

// MARK: - View model

final class PillModel: ObservableObject {
    let controller: DictationController
    let onOpenDashboard: (DashboardView.Section) -> Void
    // Reports the pill's drawn size so the panel can shrink to it.
    var onSize: ((CGSize) -> Void)?
    // Which edge the pill is parked on. Drives the 90° turn on the side anchors.
    @Published var anchor: RecordingPillController.Anchor = .bottomCentre
    // Screen coordinates of the pointer while dragging the pill to a new place.
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    init(controller: DictationController, onOpenDashboard: @escaping (DashboardView.Section) -> Void) {
        self.controller = controller
        self.onOpenDashboard = onOpenDashboard
    }

    private var dragEndedAt = Date.distantPast

    func noteDragEnded() { dragEndedAt = Date() }

    // Every pill button goes through here. The drag is a `simultaneousGesture`, so a release back
    // over the pill's frame lands on whichever button is under the cursor — that started a real
    // hands-free dictation that recorded until the app was killed. SwiftUI delivers the tap after
    // the gesture ends, so the guard is a short window rather than a flag cleared on release.
    func tapped(_ action: () -> Void) {
        guard Date().timeIntervalSince(dragEndedAt) > 0.25 else { return }
        action()
    }
}

// MARK: - SwiftUI pill

struct PillView: View {
    @ObservedObject var model: PillModel
    @ObservedObject var controller: DictationController
    // Observed, not just read: the pill draws `Theme` colours and shows the user's own shortcut
    // name, and without this it keeps whichever theme and binding it was built with until relaunch.
    @StateObject private var settings = AppSettings.shared
    @State private var hovering = false
    @State private var waveSamples: [Float] = Array(repeating: 0, count: PillView.barCount)

    static let barCount = 14

    init(model: PillModel) {
        self.model = model
        self.controller = model.controller
    }

    // Panel size per state: the layout numbers below plus `margin` on every side, and they have to
    // stay in step, since content that outgrows its entry gets clipped. A table rather than a
    // measurement, because measuring an animating view resizes the window every frame.
    //
    // Deliberately not a function of `hovering`. Resizing a window rebuilds its tracking areas, and
    // the rebuild emits a spurious `mouseExited` with no matching enter until the pointer moves — so
    // a hover-sized panel collapses under a stationary cursor. The idle panel is therefore always
    // big enough for the hover row, and `PillHitRegion` narrows the hover and drag target back down
    // to the capsule being drawn.
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

    // The panel size for a state on a given edge. A side-anchored pill is the same bar turned 90°,
    // so the panel is the transpose — the layout below never changes, only its orientation.
    static func size(for state: DictationController.State,
                     anchor: RecordingPillController.Anchor) -> CGSize {
        let flat = size(for: state)
        return anchor.isVertical ? CGSize(width: flat.height, height: flat.width) : flat
    }

    // Room for the capsule's shadow to fade out. Every point of it is also panel, and therefore
    // dead to the app underneath, so it stays as small as the shadow allows.
    private static let margin: CGFloat = 6

    private var targetSize: CGSize { Self.size(for: controller.state, anchor: model.anchor) }

    var body: some View {
        pill
            // Animations sit BELOW the frame on purpose, so they move the capsule and not the hit
            // region. The hit region has to be the panel rect exactly: the panel jumps straight to
            // its target size, so anything interpolating alongside it slides the hover region out
            // from under a stationary pointer and the pill flaps open and shut.
            .animation(Self.grow, value: controller.state)
            // Rotation keeps the unrotated layout size, so the transposed frame below is exactly
            // what the turned bar occupies, and the panel matches it.
            .rotationEffect(.degrees(model.anchor.rotation))
            // Centred, and it has to be: `rotationEffect` does not change the layout size, so on a
            // side anchor this frame is the TRANSPOSE of the child (a 122x48 bar in a 48x122 frame)
            // and only a centred frame puts the turned bar where the panel is. Aligning it to the
            // parked edge shoved the bar (122-48)/2 = 37pt off the pill on both side anchors.
            // Sized from the state but moved on the same spring as the capsule, because the two are
            // one movement. The capsule is centred in this frame, so any point by which the frame is
            // ahead of the capsule lands as HALF that much displacement: snapping it to the incoming
            // state threw the pill 19pt up the side anchors, exactly (106-68)/2, where it sat for
            // 400ms. Matching the panel instead reproduces it — the panel is not what the capsule is
            // positioned against. `targetSize` ignores `hovering`, so this animates only on a real
            // state change and the hover region never moves under a stationary pointer.
            .frame(width: targetSize.width, height: targetSize.height)
            .animation(Self.grow, value: targetSize)
            .contentShape(Rectangle())
            // `simultaneousGesture` so the hover buttons keep working: a real click never travels
            // far enough to start this, and a drag that does never lands on a button.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in model.onDragChanged?(NSEvent.mouseLocation) }
                    .onEnded { _ in model.onDragEnded?(NSEvent.mouseLocation) }
            )
            .contextMenu {
                Button("Open BisprBlow") { model.onOpenDashboard(.home) }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .onChange(of: targetSize, initial: true) { _, size in
                model.onSize?(size)
                // The panel is now the recording bar's size — the frame the reveal animates from.
                if case .recording = controller.state { ActivationTrace.mark("pill") }
            }
                // Fast attack, slow release, like a meter needle. The raw per-buffer level is spiky —
                // speech is mostly gaps — so rising is taken instantly and falling is floored at 82%
                // of the previous sample, which turns a gap into a decaying tail instead of a dropout.
            .onReceive(controller.$level) { level in
                guard case .recording = controller.state else { return }
                let previous = waveSamples.last ?? 0
                waveSamples.removeFirst()
                waveSamples.append(max(level, previous * 0.82))
            }
    }

    static let grow = Animation.spring(response: 0.32, dampingFraction: 0.82)
    // Long enough for `grow` to have visually settled. The panel waits this out before shrinking.
    static let growSettled: TimeInterval = 0.4

    // The visible capsule's own size: the `size(for:)` numbers without the shadow margin, plus the
    // one thing that table ignores — hover, which changes what is drawn, not what the panel claims.
    private var capsuleSize: CGSize {
        switch controller.state {
        case .idle: hovering ? CGSize(width: 110, height: 36) : CGSize(width: 42, height: 9)
        case .recording, .processing: box
        }
    }

    // The box the capsule is positioned inside — the panel minus the margin its shadow needs.
    private var box: CGSize {
        let panel = Self.size(for: controller.state)
        return CGSize(width: panel.width - Self.margin * 2, height: panel.height - Self.margin * 2)
    }

    // One capsule for every state, resized per state, rather than a `switch` handing back a
    // different view each time: a switch changes the view's IDENTITY, and SwiftUI can only dissolve
    // between identities, never morph — which also relaid the outgoing state into the incoming
    // state's box, giving the fade a sideways nudge. The capsule hugs `contentAlignment`, the same
    // parked edge in every state, so that edge stays put while the rest grows.
    private var pill: some View {
        capsule(Color.clear.frame(width: capsuleSize.width, height: capsuleSize.height))
            .animation(Self.grow, value: capsuleSize)
            .frame(width: box.width, height: box.height, alignment: model.anchor.contentAlignment)
            .overlay { contents }
            // Hover and drag belong to the capsule you can SEE, not the panel around it. The idle
            // panel is permanently hover-sized, and a `contentShape(Rectangle())` on it sprang the
            // pill open with the pointer up to 34pt from anything drawn. `PillHitRegion` tracks
            // `capsuleSize`, so it only ever grows while hovering.
            .contentShape(PillHitRegion(size: capsuleSize,
                                        alignment: model.anchor.contentAlignment))
            .onHover { hovering = $0 }
            .padding(Self.margin)
    }

    // What rides on the capsule. Only this cross-fades; the shape underneath it morphs.
    @ViewBuilder
    private var contents: some View {
        switch controller.state {
        case .idle:
            hoverButtons
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.86)
                .animation(Self.grow, value: hovering)
                .allowsHitTesting(hovering)
        case .recording(let locked):
            recordingPill(locked: locked)
        case .processing:
            processingPill
        }
    }

    // The dark capsule a state sits on, applied to whatever carries that state's size rather than
    // wrapped around the whole pill: for idle the capsule is the thing that grows, and a background
    // around a fixed-size parent would draw it full size the whole time.
    private func capsule(_ content: some View) -> some View {
        content.background(
            Capsule().fill(Theme.pillBackground)
                // Fits inside `margin`. A shadow wider than the panel gets clipped by the window
                // edge, and a clipped gaussian reads as a translucent rectangle around the pill.
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        )
    }

    // The glyphs counter-rotate: the bar turns 90° on a side edge, but an icon lying on its side is
    // wrong to look at. The capsule and the waveform still turn with the bar.
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
            PillCircleButton(help: "Open BisprBlow", counterRotation: upright) {
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

    // Bars top out at 16pt inside a 28pt capsule, leaving 6pt of clear pill above and below. They
    // used to reach 23pt, leaving 2.5pt, and a loud syllable read as the waveform straining against
    // the edge — a meter wants headroom it visibly never uses. `easeOut` rather than `linear`: every
    // bar's value changes each tick as the history shifts. The real smoothing is in `waveSamples`.
    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(Theme.pillWave)
                    .frame(width: 2.5, height: CGFloat(3 + waveSamples[i] * 13))
                    .animation(.easeOut(duration: 0.12), value: waveSamples[i])
            }
        }
        .frame(height: 20)
    }

    private var processingPill: some View {
        ProcessingDots()
            .padding(.horizontal, 14)
            .frame(height: 22)
    }

}

// The pill's hit region: a capsule the size of the one being drawn, where it is drawn — against
// `contentAlignment` inside the box. Lives in the pill's unrotated space, so it is applied inside
// `pill` rather than on the frame above `rotationEffect`, where the two are transposes.
struct PillHitRegion: Shape {
    let size: CGSize
    let alignment: Alignment

    func path(in rect: CGRect) -> Path {
        let x: CGFloat = switch alignment.horizontal {
        case .leading: rect.minX
        case .trailing: rect.maxX - size.width
        default: rect.midX - size.width / 2
        }
        let y: CGFloat = switch alignment.vertical {
        case .top: rect.minY
        case .bottom: rect.maxY - size.height
        default: rect.midY - size.height / 2
        }
        return Capsule().path(in: CGRect(x: x, y: y, width: size.width, height: size.height))
    }
}

// Circular action button on the hover pill, with its own hover highlight.
struct PillCircleButton<Label: View>: View {
    let help: String
    // Turned back upright when the bar itself is rotated onto a side edge.
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

// Three softly pulsing dots for the "thinking" state.
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
