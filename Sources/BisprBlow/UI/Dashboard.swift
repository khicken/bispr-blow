import AppKit
import SwiftUI

/// Main window ("Hub"): sidebar navigation + content pane, Bluejay-themed.
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

/// Which page is showing. Owned by the window controller so the pill can open
/// straight onto History.
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

        /// Sidebar grouping. Dictionary and Team share a header because both exist for one
        /// reason — feeding names to the recognizer — and Settings keeps a header of its own
        /// so the last row reads as the end of a list rather than something left over.
        /// Must cover `allCases` in order; SelfCheck asserts it.
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

    /// Stagger delay by position in the flat nav order, so groups do not restart the cascade.
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
            // A theme with brand imagery puts it here: always in view, behind nothing that has to
            // stay legible, and faded into the rail's own colour at the top so the nav never sits
            // on a picture. Themes without imagery get the flat surface and this costs nothing.
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

    /// The bare `swift build` binary has no bundle, so it reads "dev" rather than a stale literal.
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
    /// Bumped only on becoming selected — keying off `selected` also bounces the row
    /// you just navigated away from.
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

/// Sidebar wordmark. The 18pt symbol sits on the nav icons' 18pt column and the 9pt
/// spacing puts the text on their 45pt label column, so the whole rail shares two edges;
/// it spins while dictating, driven by the clock so it never snaps back on stop.
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

/// Shared page scaffold: big title, optional subtitle, one optional action on the title line,
/// consistent padding. The action sits on the title's baseline rather than above the content, so
/// the page's primary verb is always in the same place.
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

// MARK: - Home

struct HomeView: View {
    @ObservedObject var history: HistoryStore
    @StateObject private var settings = AppSettings.shared

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var averageWPM: Int {
        let timed = history.entries.filter { $0.durationSeconds > 1 }
        guard !timed.isEmpty else { return 0 }
        let rates = timed.map { Double($0.cleaned.split(separator: " ").count) / ($0.durationSeconds / 60) }
        return Int(rates.reduce(0, +) / Double(rates.count))
    }

    private var streakDays: Int {
        let days = Set(history.entries.map { Calendar.current.startOfDay(for: $0.date) })
        var streak = 0
        var day = Calendar.current.startOfDay(for: Date())
        while days.contains(day) {
            streak += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Names the user's own binding: "fn" stops being the answer the moment they rebind it.
    private var subtitle: String {
        guard settings.dictationShortcutName != nil else {
            return "Set a dictation shortcut in Settings to get started."
        }
        let lock = settings.shortcuts(for: .pushToTalk).isEmpty ? "" : " Double-tap to go hands-free."
        return "\(settings.holdHint).\(lock)"
    }

    var body: some View {
        Page(title: greeting, subtitle: subtitle) {
            HStack(spacing: 12) {
                StatCard(value: "\(history.totalWords)", label: "Words")
                StatCard(value: averageWPM > 0 ? "\(averageWPM)" : "0", label: "Avg WPM")
                StatCard(value: "\(streakDays)", label: "Day streak")
            }

            LeaderboardSection(cloud: CloudClient.shared)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Recent")
                if history.entries.isEmpty {
                    EmptyHint(text: settings.holdPhrase.map { "\($0) and say something." }
                        ?? "Set a dictation shortcut in Settings.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(history.entries.prefix(8)) { entry in
                            HistoryRow(entry: entry)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .scale(scale: 0.96).combined(with: .opacity)
                                ))
                        }
                    }
                    .animation(.bjSnap, value: history.entries.map(\.id))
                }
            }
        }
    }
}

struct StatCard: View {
    var themeID = Appearance.current
    let value: String
    let label: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.bj(27, weight: .semibold))
                .monospacedDigit()
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())   // digits roll as stats update
                .animation(.bjSoft, value: value)
            SectionLabel(label)
        }
        .card()
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: Theme.ink.opacity(hovering ? 0.07 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}

struct EmptyHint: View {
    var themeID = Appearance.current
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.bj(12))
                .foregroundStyle(Theme.blue)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(text)
                .font(.bj(13))
                .foregroundStyle(Theme.inkTertiary)
        }
        .card()
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        Page(title: "History") {
            if history.entries.isEmpty {
                EmptyHint(text: "Dictations show up here.")
            } else {
                HStack {
                    SectionLabel("\(history.entries.count) dictations")
                    Spacer()
                    Button("Clear all") { history.clear() }
                        .buttonStyle(QuietButtonStyle())
                }
                VStack(spacing: 6) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry, showRaw: true)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.96).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.bjSnap, value: history.entries.map(\.id))
            }
        }
    }
}

struct HistoryRow: View {
    var themeID = Appearance.current
    let entry: DictationEntry
    var showRaw = false
    @State private var copied = false
    @State private var hovering = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.appName.isEmpty ? "Unknown app" : entry.appName)
                    .font(.bj(11, weight: .medium))
                    .foregroundStyle(Theme.blue)
                Spacer()
                // Timestamp gives way to the copy affordance on hover — the row itself is the button.
                Text(copied ? "Copied" : hovering ? "Click to copy" : Self.timeFormatter.string(from: entry.date))
                    .font(.bj(11))
                    .foregroundStyle(copied ? Theme.green : Theme.inkSubtle)
                    .contentTransition(.opacity)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.bj(10, weight: .bold))
                        .foregroundStyle(Theme.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            Text(entry.cleaned)
                .font(.bj(13))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .lineLimit(showRaw ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showRaw, entry.raw != entry.cleaned {
                Text(entry.raw)
                    .font(.bj(12))
                    .foregroundStyle(Theme.inkSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(padding: 13)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.green.opacity(copied ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .handCursor()
        .scaleEffect(copied ? 0.99 : hovering ? 1.02 : 1)
        .shadow(color: Theme.ink.opacity(hovering ? 0.10 : 0), radius: hovering ? 12 : 7, y: hovering ? 5 : 2)
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.cleaned, forType: .string)
            withAnimation(.bjSnap) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.bjSoft) { copied = false }
            }
        }
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}

// MARK: - Dictionary

/// Curated one-click vocabulary packs.
enum VocabPacks {
    static let all: [(name: String, terms: [String])] = [
        ("Dev tools", [
            "git", "worktree", "GitHub", "VS Code", "Cursor", "Claude Code", "CLI", "npm", "pnpm",
            "Vite", "TypeScript", "JavaScript", "Python", "Swift", "regex", "JSON", "YAML",
            "Markdown", "API", "SDK", "CI/CD", "Dockerfile", "linter", "Prettier", "ESLint",
            "Xcode", "Homebrew", "zsh", "tmux", "Vim",
        ]),
        ("Cloud & infra", [
            "Kubernetes", "kubectl", "Docker", "Terraform", "AWS", "GCP", "Azure", "Vercel",
            "Cloudflare", "nginx", "PostgreSQL", "Postgres", "Redis", "Supabase", "Prisma",
            "LiveKit", "webhook", "OAuth", "JWT", "gRPC", "WebSocket", "DNS", "CDN", "S3",
            "Lambda", "cron", "Datadog", "Sentry",
        ]),
        ("AI / ML", [
            "LLM", "Anthropic", "Claude", "OpenAI", "GPT", "Gemini", "Llama", "Ollama",
            "LM Studio", "RAG", "embeddings", "fine-tuning", "inference", "transformer",
            "tokenizer", "prompt engineering", "system prompt", "Whisper", "MCP",
            "agentic", "eval", "Hugging Face", "PyTorch", "CUDA", "quantization",
        ]),
        ("Bluejay stack", [
            "Bluejay", "Next.js", "Prisma", "Supabase", "LiveKit", "middleware", "Slack",
            "Notion", "Sentry", "Twilio", "Deepgram", "BisprBlow",
        ]),
    ]
}

struct DictionaryView: View {
    @ObservedObject var settings: AppSettings
    @State private var newWord = ""
    @State private var search = ""
    @State private var recentFirst = false
    @State private var generating = false
    @State private var note: String?
    @AppStorage("dictionaryIntroDismissed") private var introDismissed = false
    private let cleaner = LLMCleaner()

    /// Search and sort only exist once the list is long enough to need them. A one-term list with
    /// a search box on it is asking a question nobody has.
    private var listIsLong: Bool { settings.dictionary.count > 8 }

    /// Typed text that is one topic rather than a list of words, which is the only case where
    /// "add everything about this" means anything.
    private var topic: String? {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, !trimmed.contains(",") else { return nil }
        return trimmed
    }

    /// What the list shows: the search narrows it, the toggle orders it. `dictionary` is stored in
    /// the order terms were added, so newest-first is simply the reverse.
    private var shown: [String] {
        let matched = search.isEmpty
            ? settings.dictionary
            : settings.dictionary.filter { $0.localizedCaseInsensitiveContains(search) }
        return recentFirst
            ? matched.reversed()
            : matched.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        Page(title: "Dictionary", subtitle: "These words stay on this Mac.") {
            if !introDismissed {
                intro
            }
            composer
            terms
            packs
        }
    }

    // MARK: Intro

    /// What the page is for, said once, and dismissible — most people will read it on their first
    /// visit and never want to see it again. The chips are the user's own terms, not samples: the
    /// point of the panel is "this is the list that makes Wispr spell your words right", and showing
    /// their words makes it immediately.
    private var intro: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 11) {
                (Text("It spells the way ")
                 + Text("you").italic()
                 + Text(" do."))
                    .font(.bj(29, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                Text("Add the names, tools, and jargon you say out loud and BisprBlow will spell them right instead of guessing. Teammate names come from the Team page.")
                    .font(.bj(13))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(2.5)
                    .frame(maxWidth: 520, alignment: .leading)
                // Terms only, no action: the field to add one sits directly below this panel, and a
                // button here would be a second control for the same job.
                HStack(spacing: 8) {
                    ForEach(settings.dictionary.suffix(5).reversed(), id: \.self) { word in
                        Text(word)
                            .font(.bj(12.5))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.white.opacity(0.16)))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 3)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(introBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                withAnimation(.bjSoft) { introDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.bj(10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Hide this")
            .padding(14)
        }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    /// A brand render where the theme has one, and the app icon's own gradient where it does not —
    /// the same dark field the pill uses, so the two surfaces read as one product either way. The
    /// scrim is what keeps white text on a photograph readable, and it is darkest where the text is.
    @ViewBuilder
    private var introBackground: some View {
        if let name = Theme.palette.panelImage, let image = Theme.image(name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.22)],
                                   startPoint: .leading, endPoint: .trailing)
                )
        } else {
            LinearGradient(colors: [Theme.blueDeep, Color(hex: 0x123A5C)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(
                    RadialGradient(colors: [Theme.blue.opacity(0.42), .clear],
                                   center: UnitPoint(x: 0.82, y: 0.18),
                                   startRadius: 4, endRadius: 340)
                )
        }
    }

    // MARK: Composer

    /// One field, always visible, and the page's only place to type.
    ///
    /// Adding words is the job; a topic is a shortcut for adding thirty of them at once. Two fields
    /// meant two ways to type with nothing to tell them apart, and the layout had it exactly
    /// backwards: the word field was hidden behind a button while the topic field sat open. So the
    /// same text now feeds both verbs, and the second verb spells out what it will do with what you
    /// typed — which is what makes the distinction legible, and only at the moment it matters.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a word or a name, or several separated by commas", text: $newWord)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .onSubmit(addWord)
                // Return adds the literal words. Asking a model for thirty terms is a bigger,
                // slower thing to do by accident, so it costs a click.
                Button("Add", action: addWord)
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let topic {
                Button(action: generate) {
                    HStack(spacing: 6) {
                        if generating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles").font(.bj(10.5))
                        }
                        Text("Add the words people use around “\(topic)”")
                            .font(.bj(12))
                    }
                    .foregroundStyle(generating ? Theme.inkSubtle : Theme.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .disabled(generating)
                .help("Asks the local model which words people use when they talk about this, and adds them all.")
                .padding(.leading, 2)
                .transition(.opacity)
            }

            if let note {
                Text(note)
                    .font(.bj(11.5))
                    .foregroundStyle(Theme.inkSubtle)
                    .padding(.leading, 2)
            }
        }
        .animation(.bjSoft, value: topic == nil)
    }

    // MARK: List

    /// A flat divided list, not chips. A quick pack adds thirty terms at once, and thirty capsules
    /// in a wrapping grid is a pile rather than a list: nothing to scan down, no order, nowhere to
    /// put a search field.
    private var terms: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel(settings.dictionary.count == 1 ? "1 term" : "\(settings.dictionary.count) terms")
                Spacer()
                if listIsLong {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.bj(11))
                            .foregroundStyle(Theme.inkSubtle)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                            .font(.bj(12.5))
                            .frame(width: 130)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(fieldBackground)
                    Button(recentFirst ? "Newest" : "A–Z") {
                        withAnimation(.bjSnap) { recentFirst.toggle() }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help(recentFirst ? "Sort alphabetically" : "Sort newest first")
                    Button("Clear all") {
                        withAnimation(.bjSnap) { settings.dictionary = [] }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .animation(.bjSoft, value: listIsLong)

            if settings.dictionary.isEmpty {
                EmptyHint(text: "Nothing here yet. Add a word, or start from a pack below.")
            } else if shown.isEmpty {
                Text("No term matches “\(search)”.")
                    .font(.bj(13))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.vertical, 6)
            } else if listIsLong {
                // The list scrolls inside itself rather than making the page grow. Thirty terms in
                // a page-height list pushed the search field and the starter packs off the top and
                // bottom of the window, so the tools for the list you were reading were the first
                // things to leave. Fixed height, because past the threshold there is always more
                // content than fits — no measuring, and no dead space on a short list.
                ScrollView {
                    rows(trailingInset: 10)
                }
                .frame(height: 340)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tableHeader))
            } else {
                rows()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tableHeader))
            }
        }
    }

    private func rows(trailingInset: CGFloat = 0) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, word in
                TermRow(word: word, first: index == 0, trailingInset: trailingInset) {
                    withAnimation(.bjSnap) { settings.dictionary.removeAll { $0 == word } }
                }
            }
        }
        .animation(.bjSnap, value: shown)
    }

    // MARK: Packs

    /// Last, and quiet: packs are how you fill an empty list on day one, not what you come back
    /// for. They are also the only path here that needs no typing, which is why they are the one
    /// bulk source that stays on the page rather than folding into the field above.
    private var packs: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Starter packs")
            WrapStack(spacing: 8) {
                ForEach(VocabPacks.all, id: \.name) { pack in
                    let missing = missingCount(pack.terms)
                    Button {
                        withAnimation(.bjSnap) { settings.addDictionaryWords(pack.terms) }
                    } label: {
                        Text(missing > 0 ? "\(pack.name) +\(missing)" : "\(pack.name) ✓")
                            .font(.bj(12, weight: .medium))
                            .foregroundStyle(missing > 0 ? Theme.blue : Theme.inkSubtle)
                            .contentTransition(.numericText())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(missing > 0 ? Theme.blueSoft : Theme.tableHeader))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(missing == 0)
                    .handCursor()
                    .animation(.bjSoft, value: missing)
                }
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func missingCount(_ terms: [String]) -> Int {
        let existing = Set(settings.dictionary.map { $0.lowercased() })
        return terms.filter { !existing.contains($0.lowercased()) }.count
    }

    /// One field for one term or a whole list — commas and newlines both split.
    private func addWord() {
        let before = settings.dictionary
        withAnimation(.bjSnap) {
            settings.addDictionaryWords(
                newWord.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
            )
        }
        // Say something only when nothing happened. A term appearing in the list, and the count
        // above it changing, is the confirmation — a line of text repeating it is a second control
        // for a job the list already does, and the old one never went away once it had appeared.
        // Compared as arrays, not counts: a case-only re-add changes a term without changing the count.
        note = settings.dictionary == before ? "Already in the dictionary." : nil
        if settings.dictionary != before { newWord = "" }
    }

    private func generate() {
        guard let topic, !generating else { return }
        generating = true
        note = nil
        Task { @MainActor in
            let terms = await cleaner.generateTerms(topic: topic)
            let before = settings.dictionary.count
            withAnimation(.bjSnap) { settings.addDictionaryWords(terms) }
            let added = settings.dictionary.count - before
            note = switch added {
            case 0 where terms.isEmpty:
                "No model reachable. Start LM Studio and try this again."
            case 0:
                "Every term for “\(topic)” is already in the dictionary."
            default:
                nil
            }
            if added > 0 { newWord = "" }
            generating = false
        }
    }
}

/// One term. Removal is the only action, so it is the only control, and it appears on hover rather
/// than sitting on every row — a list of a hundred terms should read as words, not as buttons.
struct TermRow: View {
    var themeID = Appearance.current
    let word: String
    let first: Bool
    /// Extra room on the right for the overlay scrollbar, which draws over the content and
    /// otherwise lands on top of the remove button. Only the scrolling list passes it; the
    /// divider stays full width either way, so the inset never reads as a ragged edge.
    var trailingInset: CGFloat = 0
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
            }
            HStack(spacing: 8) {
                Text(word)
                    .font(.bj(13))
                    .foregroundStyle(Theme.ink)
                Spacer()
                // A trash bin rather than an ✕: ✕ is dismiss, and this deletes a saved word.
                // The button is the full height of the row and wide enough to hit without
                // aiming, since it only appears once the pointer is already here.
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.bj(11.5))
                        .foregroundStyle(Theme.inkSubtle)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("Remove \(word)")
                .opacity(hovering ? 1 : 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8 + trailingInset)
            // The button is taller than the old one, so the row keeps its height from the
            // button rather than gaining eight points of padding around it.
            .padding(.vertical, 4)
            .frame(minHeight: 38)
        }
        // Full strength, not 60%: the row under the pointer is the one about to lose a term,
        // and a highlight you have to look for is why aiming at the button felt like a guess.
        .background(hovering ? Theme.surfaceActive : .clear)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
        .transition(.opacity)
    }
}

/// Left-aligned wrapping flow layout (chips/tags grid).
struct WrapStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Team

/// Team is the cloud page, so it is behind sign-in — Kaleb's call, knowing it puts a door in front
/// of the local name list, which works offline and has nothing to do with accounts.
///
/// The `CloudConfig.ready` branch is what keeps that honest rather than cruel: a build with no
/// project configured has no sign-in to pass, so gating there would not hide the name list behind a
/// door, it would delete it. Normal builds never take that path — the project is compiled in.
struct TeamPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var cloud: CloudClient

    var body: some View {
        if !CloudConfig.ready {
            TeamView(settings: settings)
        } else if cloud.session == nil {
            Page(title: "Team",
                 subtitle: "Sign in to share a leaderboard, and to keep your teammates' names spelled right.") {
                SignInView(cloud: cloud, showsBlurb: false)
                    .card(padding: 16)
            }
        } else {
            TeamView(settings: settings, cloud: cloud)
        }
    }
}

struct TeamView: View {
    @ObservedObject var settings: AppSettings
    /// nil in a build with no project configured, where there is no cloud team to show.
    var cloud: CloudClient?
    @State private var newName = ""
    @State private var newRole = ""

    var body: some View {
        // What it does, not how it works: "added to the dictation vocabulary" is our word for our
        // own mechanism, and a teammate list is worth having for exactly one reason — a name you
        // say out loud comes back spelled wrong until it is in here.
        Page(title: "Team", subtitle: "Teammate names get spelled right when you dictate them.") {
            if let cloud {
                TeamCloudSection(cloud: cloud)
                    .card(padding: 16)
            }
            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(addMember)
                TextField("Role (optional)", text: $newRole)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(addMember)
                Button("Add", action: addMember)
                    .buttonStyle(CapsuleButtonStyle())
            }

            if settings.teamMembers.isEmpty {
                // The state, then the control — the same job the Dictionary page's empty hint
                // does. Naming a scenario ("standups and reviews") pictured a workplace instead
                // of saying anything, and the subtitle right above already carries the why.
                EmptyHint(text: "Nothing here yet. Add a name above.")
            } else {
                VStack(spacing: 6) {
                    ForEach(settings.teamMembers) { member in
                        TeamRow(member: member) {
                            withAnimation(.bjSnap) { settings.teamMembers.removeAll { $0.id == member.id } }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.94).combined(with: .opacity)
                        ))
                    }
                }
                .animation(.bjSnap, value: settings.teamMembers.map(\.id))
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func addMember() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation(.bjSnap) {
            settings.teamMembers.append(TeamMember(name: name, role: newRole.trimmingCharacters(in: .whitespaces)))
        }
        newName = ""
        newRole = ""
    }
}

struct TeamRow: View {
    var themeID = Appearance.current
    let member: TeamMember
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.blueSoft)
                Text(String(member.name.prefix(1)).uppercased())
                    .font(.bj(12.5, weight: .semibold))
                    .foregroundStyle(Theme.blue)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.bj(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !member.role.isEmpty {
                    Text(member.role)
                        .font(.bj(11))
                        .foregroundStyle(Theme.inkSubtle)
                }
            }
            Spacer()
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.bj(11))
                        .foregroundStyle(Theme.red)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 11)
        .scaleEffect(hovering ? 1.012 : 1)
        .shadow(color: Theme.ink.opacity(hovering ? 0.07 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}
