import SwiftUI

/// A whole look, in one value. Every colour the app draws comes from here, so a theme is a table
/// rather than a set of conditionals sprinkled through the views.
struct Palette {
    let cream, surface, surfaceActive, tableHeader, border: Color
    let ink, inkSecondary, inkTertiary, inkSubtle: Color
    let blue, blueDeep, red, green: Color
    /// Behind a text field. Its own token rather than `.white`, which is what it used to be —
    /// a literal that is invisible in a light theme and a flashbang in a dark one.
    let field: Color
    let pillBackground, pillWave: Color
    /// Brand imagery, by resource name, or nil where a theme wants none. Optional rather than
    /// checked against the theme in each view: a surface asks for the picture it would draw and
    /// gets nothing back, so adding a theme never means finding every `if`.
    var sidebarImage: String?
    var panelImage: String?
    /// Type face, first installed wins, empty means the system face. A theme owning the font is
    /// what lets one of them be a joke without every view knowing about it.
    var fontNames: [String] = []
}

/// Which look is in use. Add a case, add a palette, and it appears in Settings.
enum Appearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case world = "World"
    case unhinged = "Unhinged"

    var id: String { rawValue }

    /// Whether this look wants dark native controls. Switches, menus, scrollbars and the traffic
    /// lights are AppKit's to draw, so the palette alone would leave a dark window wearing light
    /// buttons.
    var isDark: Bool {
        switch self {
        case .dark: true
        case .system: AppSettings.shared.systemIsDark
        default: false
        }
    }

    var palette: Palette {
        switch self {
        case .system: AppSettings.shared.systemIsDark ? Self.dusk : Self.paper
        case .light: Self.paper
        case .dark: Self.dusk
        case .world: Self.brandWorld
        case .unhinged: Self.carnival
        }
    }

    /// Matches bluejay_frontend_v2 globals.css.
    private static let paper = Palette(
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
        field: .white,
        // Dark over any wallpaper, like Wispr's, and translucent enough to read as glass over it.
        // The wave and the glyphs are white, so the floor is contrast against a light wallpaper
        // rather than taste: below about 0.7 the bars start disappearing into a bright desktop.
        pillBackground: Color(hex: 0x1C1D1F).opacity(0.78),
        pillWave: .white
    )

    /// The light palette turned over, not inverted — and deliberately charcoal rather than black.
    /// Black gives the steps between page, rail and card nowhere to go: the first attempt ran
    /// 0x141517 / 0x191A1D / 0x1F2124 and the three read as one flat void whose edges you had to
    /// hunt for. Starting the page at 0x1D1F22 buys every surface a visible step, and keeps the
    /// faint blue-grey cast the light theme has instead of going pure neutral.
    ///
    /// Surfaces climb from the page up to the card, the reverse of paper (where a card sits
    /// *below* the page) and the right way round here: lighter reads as nearer on a dark field.
    ///
    /// The accent lifts to 0x3DB2FF because 0x1FA2FF goes muddy against dark, and the pill is left
    /// exactly as it is — it draws over the user's wallpaper, which has no opinion about our theme.
    private static let dusk = Palette(
        cream: Color(hex: 0x1D1F22),
        surface: Color(hex: 0x24272B),
        surfaceActive: Color(hex: 0x353A40),
        tableHeader: Color(hex: 0x282C30),
        border: Color(hex: 0x3D4249),
        ink: Color(hex: 0xECEEF1),
        inkSecondary: Color(hex: 0xCED2D7),
        inkTertiary: Color(hex: 0x9CA3AB),
        inkSubtle: Color(hex: 0x7A818A),
        blue: Color(hex: 0x3DB2FF),
        blueDeep: Color(hex: 0x0B2A45),
        red: Color(hex: 0xF87171),
        green: Color(hex: 0x4ADE80),
        field: Color(hex: 0x2E3238),
        pillBackground: Color(hex: 0x1C1D1F).opacity(0.78),
        pillWave: .white
    )

    /// Sampled from the brand world renders in assets/world: cyan skies, lavender clouds,
    /// magenta light. Ink goes deep violet rather than grey so text belongs to the same
    /// world, and the bar goes violet-black so it reads as night in it.
    private static let brandWorld = Palette(
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
        field: .white,
        pillBackground: Color(hex: 0x241638).opacity(0.8),
        pillWave: Color(hex: 0xB8F0FA),
        sidebarImage: "World_Secondary",
        panelImage: "World_Abstract"
    )

    /// The joke. Bubblegum page, lime rail, hot pink accent, slime green for anything that went
    /// right, and Comic Sans where the machine has it (Chalkboard SE is what macOS ships instead).
    ///
    /// Contrast is the one thing it does not joke about: ink is near-black violet on every surface
    /// here, so the text stays as readable as it is in Light. A theme nobody can read is not funny,
    /// it is just broken — and someone will leave this on.
    private static let carnival = Palette(
        cream: Color(hex: 0xFFF0FA),
        surface: Color(hex: 0xDDFB9E),
        surfaceActive: Color(hex: 0xFDE047),
        tableHeader: Color(hex: 0xCBF7FF),
        border: Color(hex: 0x8B27C9),
        ink: Color(hex: 0x1B0033),
        inkSecondary: Color(hex: 0x4A0D7A),
        inkTertiary: Color(hex: 0x7C1FBF),
        inkSubtle: Color(hex: 0x9B2FA8),
        blue: Color(hex: 0xFF00A8),
        blueDeep: Color(hex: 0x3D0066),
        red: Color(hex: 0xFF0054),
        green: Color(hex: 0x2FBF14),
        field: Color(hex: 0xFFFBD6),
        pillBackground: Color(hex: 0x7C1FBF).opacity(0.82),
        pillWave: Color(hex: 0xC6FF3D),
        fontNames: ["Comic Sans MS", "Chalkboard SE", "Marker Felt"]
    )
}

/// The colours in play right now. Static so every call site stays a plain `Theme.ink`, computed so
/// switching appearance repaints instead of needing a relaunch. Anything that draws one of these
/// must store `var themeID = Appearance.current`, or it keeps the palette it was built with — see
/// the note on `Appearance.current` for why observing `AppSettings` is not enough.
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
    static var field: Color { palette.field }
    static var pillBackground: Color { palette.pillBackground }
    static var pillWave: Color { palette.pillWave }

    /// The face this theme asks for, or nil for the system one. Resolved against what is actually
    /// installed — `Font.custom` falls back silently, so an uninstalled Comic Sans would look like
    /// a theme that simply forgot to change the font.
    static var fontName: String? {
        let wanted = palette.fontNames
        if let hit = resolvedFont, hit.wanted == wanted { return hit.name }
        let name = wanted.first { NSFont(name: $0, size: 12) != nil }
        resolvedFont = (wanted, name)
        return name
    }

    private nonisolated(unsafe) static var resolvedFont: (wanted: [String], name: String?)?

    /// AppKit draws the switches, menus, scrollbars and traffic lights, and it takes no notice of
    /// `Palette`. Called at launch and whenever the setting changes; nil hands the decision back
    /// to macOS, which is exactly what System means.
    static func applyToNativeControls() {
        let appearance = AppSettings.shared.appearance
        NSApp?.appearance = appearance == .system
            ? nil
            : NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
    }

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

extension Font {
    /// Every piece of type in the app goes through here instead of `.system(size:)`, so a theme
    /// can own the face as well as the colours. Same argument order, one word shorter, and it is
    /// the only place that knows a custom face has to carry its weight separately.
    static func bj(_ size: CGFloat, weight: Font.Weight = .regular,
                   design: Font.Design = .default) -> Font {
        guard let name = Theme.fontName else {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(name, fixedSize: size).weight(weight)
    }
}

extension Appearance {
    /// Store this in any view, modifier or button style that draws a palette colour:
    ///
    ///     var themeID = Appearance.current
    ///
    /// `Theme` is a table of static properties, so a view drawing `Theme.ink` holds nothing that
    /// depends on the theme. SwiftUI compares a view's stored properties and skips redrawing when
    /// they match, so switching appearance left every such view with the palette it was built
    /// with — a cream card on a black page, carrying white text. A stored value that changes with
    /// the theme is what makes that comparison notice.
    ///
    /// A plain stored property and not `@ObservedObject`: `ViewModifier` and `ButtonStyle` cannot
    /// observe anything, and `Card` was the worst offender of the lot. Views whose other stored
    /// properties already differ on every render (a closure, usually) redrew by luck. This makes
    /// it a rule instead.
    static var current: Appearance { AppSettings.shared.appearance }
}

/// Uppercase micro-label for section headers.
struct SectionLabel: View {
    var themeID = Appearance.current
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.bj(10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.inkSubtle)
    }
}

/// Flat card: soft fill, no border.
struct Card: ViewModifier {
    var themeID = Appearance.current
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
    var themeID = Appearance.current
    var filled = true
    /// Ink for a page's primary verb, blue for accents inside content. Blue is an accent, not a
    /// surface (CLAUDE.md), and a page full of blue capsules leaves nothing for the accent to mean.
    var tint: Color = Theme.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bj(13, weight: .medium))
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
    var themeID = Appearance.current
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bj(12))
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
