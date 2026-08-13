import AppKit

/// Drives the pill through a real release transition and measures where it lands, once per frame.
///
/// Three sessions have now tried to fix "the pill jumps" by reading the code and asking Kaleb what
/// he saw, and two of them shipped a regression. This is `--mic-check` for the pill: the transition
/// is a 0.32s spring plus a panel resize deferred 0.4s, so the thing to know is what moves and when,
/// and neither is answerable by reasoning about a static file.
///
/// It measures **drawn pixels plus the panel's own origin**, not SwiftUI's layout.
/// `rotationEffect` leaves the layout size unrotated and the panel is resized by AppKit on a clock
/// of its own, so a layout probe would miss whichever of the two is at fault. Screen capture would
/// be the obvious tool and is not available: `CGWindowListCreateImage` is gone in macOS 26 and
/// ScreenCaptureKit wants a permission this app deliberately does not hold. Rendering our own view
/// needs neither, and the panel's screen origin is exact from AppKit.
enum PillDemo {
    /// Alpha above this counts as pill. The capsule's shadow peaks at 0.35, so this measures the
    /// bar rather than the glow around it.
    private static let opaque: UInt8 = 128

    struct Sample {
        let ms: Int
        let state: String
        /// The pill's drawn edges in screen points, bottom-left origin — the axis the jump is on.
        let bottom, top: CGFloat
        let panel: NSRect
    }

    @MainActor
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // `--pill-demo leftCentre` picks the edge. It has to be an argument: this binary is not the
        // installed bundle, so `UserDefaults.standard` is its own domain and it never sees the real
        // `pillAnchor` — which also means writing it here cannot disturb the user's own setting.
        // The side anchors are the interesting ones; the bottom anchor hides these bugs, because
        // there the panel and its child are the same size and every alignment is a no-op at rest.
        if let raw = CommandLine.arguments.dropFirst().first(
            where: { RecordingPillController.Anchor(rawValue: $0) != nil }) {
            UserDefaults.standard.set(raw, forKey: "pillAnchor")
        }

        // No `controller.start()`: that installs the shortcut event tap, and a second tap fighting
        // the installed copy is the one failure mode build.sh exists to prevent.
        let controller = DictationController()
        let pill = RecordingPillController(controller: controller) { _ in }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        let anchor = UserDefaults.standard.string(forKey: "pillAnchor") ?? "bottomCentre"
        print("anchor: \(anchor)  layout: \(RecordingPillController.layoutFrame(screen).debugDescription)")

        var samples: [Sample] = []
        let started = Date()
        // A real release: hold, speak, let go, and ~476ms later the text lands. That gap is the
        // measured median post-release latency, and it straddles the 0.4s deferred panel shrink —
        // which is the whole reason the sequence is worth replaying rather than posed.
        let script: [(TimeInterval, DictationController.State, String)] = [
            (0.60, .recording(locked: false), "recording"),
            (2.00, .processing, "processing"),
            (2.48, .idle, "idle"),
        ]
        var label = "idle"
        for (at, state, name) in script {
            Timer.scheduledTimer(withTimeInterval: at, repeats: false) { _ in
                MainActor.assumeIsolated {
                    controller.demoState(state)
                    label = name
                }
            }
        }

        // 120Hz. The spring is 0.32s and the deferral 0.4s, so 8ms resolution puts ~40 samples
        // inside the first movement and ~10 across the gap between the two.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                guard ms < 3600 else {
                    timer.invalidate()
                    report(samples)
                    exit(0)
                }
                // Only the release is interesting; idle before the first state change is noise.
                guard ms > 1900 else { return }
                guard let edges = edges(of: pill.panel) else { return }
                samples.append(Sample(ms: ms, state: label, bottom: edges.bottom, top: edges.top,
                                      panel: pill.panel.frame))
            }
        }

        app.run()
        exit(0)
    }

    /// The pill's top and bottom edge in screen points: the drawn extent inside the panel, offset by
    /// the panel's own origin. Both halves matter — the capsule animates inside a panel that is
    /// itself moving and resizing, and either one alone would look stationary.
    @MainActor
    private static func edges(of panel: NSPanel) -> (bottom: CGFloat, top: CGFloat)? {
        guard let view = panel.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4 else { return nil }

        let width = rep.pixelsWide, height = rep.pixelsHigh, stride = rep.bytesPerRow
        let alphaOffset = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        // Row 0 is the top of the rect; the panel's y grows upward, so the two are counted opposite
        // ways and the first hit row is the *highest* point on screen.
        var firstRow = -1, lastRow = -1
        for row in 0..<height {
            let base = row * stride
            var hit = false
            for column in 0..<width where data[base + column * 4 + alphaOffset] > opaque {
                hit = true
                break
            }
            if hit {
                if firstRow < 0 { firstRow = row }
                lastRow = row
            }
        }
        guard firstRow >= 0 else { return nil }
        let scale = CGFloat(height) / bounds.height
        return (panel.frame.minY + bounds.height - CGFloat(lastRow + 1) / scale,
                panel.frame.minY + bounds.height - CGFloat(firstRow) / scale)
    }

    private static func report(_ samples: [Sample]) {
        guard !samples.isEmpty else { return print("no samples — the panel drew nothing") }
        print("\n  ms  state       bottom     top   height   centre   drift   panel.y  panel.h")
        var lastCentre: CGFloat?
        for sample in samples {
            let centre = (sample.bottom + sample.top) / 2
            let drift = lastCentre.map { String(format: "%+6.2f", centre - $0) } ?? "      "
            lastCentre = centre
            let numbers = String(format: "%7.2f %7.2f %8.2f %8.2f", sample.bottom, sample.top,
                                 sample.top - sample.bottom, centre)
            let panel = String(format: "%7.1f %8.1f", sample.panel.origin.y, sample.panel.height)
            print("\(String(sample.ms).leftPad(4))  \(sample.state.rightPad(10)) \(numbers) \(drift)   \(panel)")
        }
        let centres = samples.map { ($0.bottom + $0.top) / 2 }
        let tops = samples.map(\.top), bottoms = samples.map(\.bottom)
        for (name, values) in [("centre", centres), ("top   ", tops), ("bottom", bottoms)] {
            print(String(format: "\n%@: %.2f .. %.2f  (travel %.2fpt)",
                         name, values.min()!, values.max()!, values.max()! - values.min()!))
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
    func rightPad(_ width: Int) -> String { self + String(repeating: " ", count: max(0, width - count)) }
}
