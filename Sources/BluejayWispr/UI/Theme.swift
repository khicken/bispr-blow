import SwiftUI

/// Bluejay brand palette (matches bluejay_frontend_v2 globals.css).
enum Theme {
    static let cream = Color(hex: 0xFDFDFB)        // bg-cream
    static let surface = Color(hex: 0xF9FAF8)      // bg-sidebar / bg-content
    static let surfaceActive = Color(hex: 0xECEEE9) // nav-bg-active
    static let tableHeader = Color(hex: 0xF4F5F1)
    static let border = Color(hex: 0xD7DCDA)
    static let ink = Color(hex: 0x2D2D2D)          // text-primary
    static let inkSecondary = Color(hex: 0x404040)
    static let inkTertiary = Color(hex: 0x5C5C5C)
    static let inkSubtle = Color(hex: 0x8C8C8C)
    static let blue = Color(hex: 0x1FA2FF)         // accent
    static let blueDeep = Color(hex: 0x0B2A45)     // app-icon gradient end
    static let blueSoft = Color(hex: 0x1FA2FF).opacity(0.12)
    static let red = Color(hex: 0xEF4444)
    static let green = Color(hex: 0x15803D)

    // Flow-bar pill (dark over any wallpaper, like Wispr's)
    static let pillBackground = Color(hex: 0x1C1D1F).opacity(0.92)
    static let pillWave = Color.white

    static func logo(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources")
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

    /// Pointing-hand cursor. Set through AppKit — `pointerStyle` no-ops on hosted views.
    func handCursor() -> some View {
        onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(filled ? .white : Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(filled ? Theme.blue : Theme.surfaceActive))
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
