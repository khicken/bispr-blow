import SwiftUI

/// A whole look, in one value. Every colour the app draws comes from here, so a theme is a table
/// rather than a set of conditionals sprinkled through the views.
struct Palette {
    let cream, surface, surfaceActive, tableHeader, border: Color
    let ink, inkSecondary, inkTertiary, inkSubtle: Color
    let blue, blueDeep, red, green: Color
    let pillBackground, pillWave: Color
    /// Brand imagery, by resource name, or nil where a theme wants none. Optional rather than
    /// checked against the theme in each view: a surface asks for the picture it would draw and
    /// gets nothing back, so adding a theme never means finding every `if`.
    var sidebarImage: String?
    var panelImage: String?
    var previewImage: String?
}

/// Which look is in use. Add a case, add a palette, and it appears in Settings.
enum Appearance: String, CaseIterable, Identifiable {
    case bluejay = "Bluejay"
    case bluejayWorld = "Bluejay World"

    var id: String { rawValue }

    /// One line under the name in Settings. What it looks like, not how it works.
    var blurb: String {
        switch self {
        case .bluejay: "Paper and ink, with a blue accent."
        case .bluejayWorld: "The brand world: soft colour, dark violet bar."
        }
    }

    var palette: Palette {
        switch self {
        case .bluejay:
            // Matches bluejay_frontend_v2 globals.css.
            Palette(
                cream: Color(hex: 0xFDFDFB),          // bg-cream
                surface: Color(hex: 0xF9FAF8),        // bg-sidebar / bg-content
                surfaceActive: Color(hex: 0xECEEE9),  // nav-bg-active
                tableHeader: Color(hex: 0xF4F5F1),
                border: Color(hex: 0xD7DCDA),
                ink: Color(hex: 0x2D2D2D),            // text-primary
                inkSecondary: Color(hex: 0x404040),
                inkTertiary: Color(hex: 0x5C5C5C),
                inkSubtle: Color(hex: 0x8C8C8C),
                blue: Color(hex: 0x1FA2FF),           // accent
                blueDeep: Color(hex: 0x0B2A45),       // app-icon gradient end
                red: Color(hex: 0xEF4444),
                green: Color(hex: 0x15803D),
                // Dark over any wallpaper, like Wispr's.
                pillBackground: Color(hex: 0x1C1D1F).opacity(0.92),
                pillWave: .white
            )
        case .bluejayWorld:
            // Sampled from the brand world renders in assets/world: cyan skies, lavender clouds,
            // magenta light. Ink goes deep violet rather than grey so text belongs to the same
            // world, and the bar goes violet-black so it reads as night in it.
            Palette(
                cream: Color(hex: 0xFBF8FF),
                surface: Color(hex: 0xF5F0FF),
                surfaceActive: Color(hex: 0xE7DDFB),
                tableHeader: Color(hex: 0xF0EAFD),
                border: Color(hex: 0xDDD1F4),
                ink: Color(hex: 0x241A47),
                inkSecondary: Color(hex: 0x3A2C68),
                inkTertiary: Color(hex: 0x5B4C8A),
                inkSubtle: Color(hex: 0x9086B0),
                blue: Color(hex: 0x2BC4DE),            // the bird
                blueDeep: Color(hex: 0x2A1B4A),
                red: Color(hex: 0xF0479B),             // the sky
                green: Color(hex: 0x1FAE9C),
                pillBackground: Color(hex: 0x241638).opacity(0.94),
                pillWave: Color(hex: 0xB8F0FA),
                sidebarImage: "World_Secondary",
                panelImage: "World_Abstract",
                previewImage: "World_Scene"
            )
        }
    }
}

/// The colours in play right now. Static so every call site stays a plain `Theme.ink`, computed so
/// switching appearance repaints instead of needing a relaunch. Views that draw these must observe
/// `AppSettings`, or they keep the palette they were built with.
enum Theme {
    static var palette: Palette { AppSettings.shared.appearance.palette }

    static var cream: Color { palette.cream }
    static var surface: Color { palette.surface }
    static var surfaceActive: Color { palette.surfaceActive }
    static var tableHeader: Color { palette.tableHeader }
    static var border: Color { palette.border }
    static var ink: Color { palette.ink }
    static var inkSecondary: Color { palette.inkSecondary }
    static var inkTertiary: Color { palette.inkTertiary }
    static var inkSubtle: Color { palette.inkSubtle }
    static var blue: Color { palette.blue }
    static var blueDeep: Color { palette.blueDeep }
    static var blueSoft: Color { palette.blue.opacity(0.12) }
    static var red: Color { palette.red }
    static var green: Color { palette.green }
    static var pillBackground: Color { palette.pillBackground }
    static var pillWave: Color { palette.pillWave }

    static func logo(_ name: String) -> NSImage? { asset(name, extension: "svg") }

    /// Brand imagery. Cached: these are photographs, and a SwiftUI body can run many times a second.
    static func image(_ name: String) -> NSImage? {
        if let hit = imageCache[name] { return hit }
        let loaded = asset(name, extension: "jpg")
        imageCache[name] = loaded
        return loaded
    }

    private nonisolated(unsafe) static var imageCache: [String: NSImage?] = [:]

    private static func asset(_ name: String, extension ext: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Uppercase micro-label for section headers.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.inkSubtle)
    }
}

/// Flat card: soft fill, no border.
struct Card: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tableHeader))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(Card(padding: padding)) }

    /// Fade + rise on first appearance; `delay` staggers siblings.
    func appearIn(_ delay: Double = 0) -> some View { modifier(AppearIn(delay: delay)) }

    /// Pointing-hand cursor over this view.
    func handCursor() -> some View {
        overlay(HandCursorRect().allowsHitTesting(false))
    }
}

/// A cursor rect, not `NSCursor.set()` on hover: the window owns cursor updates, so setting
/// the cursor directly flickers whenever a click causes a redraw. `pointerStyle` no-ops here.
private struct HandCursorRect: NSViewRepresentable {
    final class RectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func makeNSView(context: Context) -> RectView { RectView() }

    func updateNSView(_ view: RectView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
}

struct AppearIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 9)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86).delay(delay)) { shown = true }
            }
    }
}

/// Shared motion vocabulary so every surface eases the same way.
extension Animation {
    static let bjSnap = Animation.spring(response: 0.30, dampingFraction: 0.78)
    static let bjSoft = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let bjHover = Animation.easeOut(duration: 0.13)
}

/// Standard pill button: full-capsule hit area + pressed feedback.
struct CapsuleButtonStyle: ButtonStyle {
    var filled = true
    /// Ink for a page's primary verb, blue for accents inside content. Blue is an accent, not a
    /// surface (CLAUDE.md), and a page full of blue capsules leaves nothing for the accent to mean.
    var tint: Color = Theme.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(filled ? .white : Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(filled ? tint : Theme.surfaceActive))
            .contentShape(Capsule())
            .handCursor()
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.bjSnap, value: configuration.isPressed)
    }
}

/// Quiet text button with a real hit area (small actions like "Clear all").
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkSubtle)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Theme.surfaceActive : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .handCursor()
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.bjSnap, value: configuration.isPressed)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
