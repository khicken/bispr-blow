import AppKit
import SwiftUI

// Main window ("Hub"): sidebar navigation + content pane, Bluejay-themed.
final class DashboardWindowController {
    private var window: NSWindow?
    private let controller: DictationController
    private let nav = DashboardNav()

    init(controller: DictationController) {
        self.controller = controller
    }

    func show(_ section: DashboardView.Section = .home) {
        nav.section = section
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.minSize = NSSize(width: 760, height: 520)
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: DashboardView(controller: controller, nav: nav))
            window = win
        }
        guard let win = window else { return }
        // Center on the screen the user is actually on (mouse position). The pill is a
        // non-activating panel, so NSScreen.main can be a different display entirely.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            win.setFrameOrigin(NSPoint(
                x: frame.midX - win.frame.width / 2,
                y: frame.midY - win.frame.height / 2
            ))
        }
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }
}

// MARK: - Root view

// Which page is showing. Owned by the window controller so the pill can open straight onto History.
final class DashboardNav: ObservableObject {
    @Published var section: DashboardView.Section = .home
}

struct DashboardView: View {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home"
        case history = "History"
        case dictionary = "Dictionary"
        case team = "Team"
        case settings = "Settings"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house"
            case .history: return "clock.arrow.circlepath"
            case .dictionary: return "character.book.closed"
            case .team: return "person.2"
            case .settings: return "gearshape"
            }
        }

        // Sidebar grouping. Dictionary and Team share a header because both feed names to the
        // recognizer; Settings keeps its own so the last row reads as the end of a list. Must cover
        // `allCases` in order; SelfCheck asserts it.
        static let groups: [(title: String, items: [Section])] = [
            ("Activity", [.home, .history]),
            ("Vocabulary", [.dictionary, .team]),
            ("App", [.settings]),
        ]
    }

    @ObservedObject var controller: DictationController
    @ObservedObject var nav: DashboardNav
    @StateObject private var history = HistoryStore.shared
    @StateObject private var settings = AppSettings.shared
    @Namespace private var navPill

    private var section: Section { nav.section }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.cream)
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(settings.appearance.isDark ? .dark : .light)
    }

    // Stagger delay by position in the flat nav order, so groups do not restart the cascade.
    private func navDelay(_ item: Section) -> Double {
        0.05 + Double(Section.allCases.firstIndex(of: item) ?? 0) * 0.035
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup(state: controller.state)
                .padding(.horizontal, 18)
                .padding(.top, 42)
                .padding(.bottom, 26)

            ForEach(Array(Section.groups.enumerated()), id: \.element.title) { groupIndex, group in
                // Headers sit on the 18pt column with the nav icons and the wordmark symbol,
                // so the rail has one left edge rather than two.
                SectionLabel(group.title)
                    .padding(.horizontal, 18)
                    .padding(.top, groupIndex == 0 ? 0 : 22)
                    .padding(.bottom, 7)
                    .appearIn(navDelay(group.items[0]))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.items) { item in
                        SidebarItem(item: item, selected: section == item, namespace: navPill) {
                            withAnimation(.bjSnap) { nav.section = item }
                        }
                        .appearIn(navDelay(item))
                    }
                }
            }

            Spacer()

            Text(Self.versionLabel)
                .font(.bj(10.5))
                .foregroundStyle(Theme.inkSubtle.opacity(0.75))
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
        .frame(width: 250)
        .background(alignment: .bottom) {
            // A theme with brand imagery puts it here, faded into the rail's colour at the top so the
            // nav never sits on a picture. Themes without imagery get the flat surface.
            ZStack(alignment: .bottom) {
                Theme.surface
                if let name = Theme.palette.sidebarImage, let image = Theme.image(name) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 300)
                        .frame(maxWidth: 250)
                        .clipped()
                        .mask(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border.opacity(0.55)).frame(width: 1)
        }
    }

    // The bare `swift build` binary has no bundle, so it reads "dev" rather than a stale literal.
    private static let versionLabel =
        "Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")

    @ViewBuilder
    private var content: some View {
        Group {
            switch section {
            case .home: HomeView(history: history)
            case .history: HistoryView(history: history)
            case .dictionary: DictionaryView(settings: settings)
            case .team: TeamPage(settings: settings, cloud: CloudClient.shared)
            case .settings: SettingsView(settings: settings)
            }
        }
        .id(section)
        .transition(.asymmetric(
            insertion: .offset(y: 10).combined(with: .opacity),
            removal: .offset(y: -6).combined(with: .opacity)
        ))
        .animation(.bjSoft, value: section)
    }
}

struct SidebarItem: View {
    var themeID = Appearance.current
    let item: DashboardView.Section
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    // Bumped only on becoming selected — keying off `selected` also bounces the row you just left.
    @State private var bounce = 0

    var body: some View {
        Button(action: action) {
            // Icon at 18pt from the sidebar edge (8 outer + 10 inner), label at 45 (18 + 18 + 9).
            // BrandLockup repeats both numbers; change one, change all four.
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.bj(12.5, weight: .medium))
                    .frame(width: 18)
                    .symbolEffect(.bounce, options: .speed(1.5), value: bounce)
                Text(item.rawValue)
                    .font(.bj(13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.blue : Theme.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 10.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // One pill that slides between rows, rather than a fill per row.
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.blueSoft)
                        .matchedGeometryEffect(id: "navPill", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceActive.opacity(0.6))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .offset(x: hovering && !selected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
        .onChange(of: selected) { _, isSelected in
            if isSelected { bounce += 1 }
        }
    }
}

// Sidebar wordmark. 18pt symbol on the nav icons' 18pt column, 9pt spacing putting the text on
// their 45pt label column. It spins while dictating, driven by the clock so it never snaps back.
struct BrandLockup: View {
    var themeID = Appearance.current
    let state: DictationController.State

    private var live: Bool { state != .idle }

    var body: some View {
        HStack(spacing: 9) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { ctx in
                LogoView(name: "Symbol_Black", size: 18)
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 115))
            }
            .frame(width: 18, height: 18)
            Text("BisprBlow")
                .font(.bj(13.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Theme.ink)
        }
    }
}

struct LogoView: View {
    var themeID = Appearance.current
    let name: String
    let size: CGFloat

    var body: some View {
        if let image = Theme.logo(name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bird")
                .font(.bj(size - 6))
                .foregroundStyle(Theme.blue)
        }
    }
}

// Shared page scaffold: big title, optional subtitle, one optional action on the title line. The
// action sits on the title's baseline so the page's primary verb is always in the same place.
struct Page<Content: View>: View {
    var themeID = Appearance.current
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.bj(27, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.bj(13))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                .appearIn()
                content()
                    .appearIn(0.07)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
