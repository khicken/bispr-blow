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
        .preferredColorScheme(.light)
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

            VStack(alignment: .leading, spacing: 9) {
                LiveStatus(state: controller.state)
                Text(Self.versionLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkSubtle.opacity(0.75))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 250)
        .background(Theme.surface)
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
            case .team: TeamView(settings: settings)
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
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                    .symbolEffect(.bounce, options: .speed(1.5), value: bounce)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
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
    let state: DictationController.State

    private var live: Bool { state != .idle }

    var body: some View {
        HStack(spacing: 9) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { ctx in
                LogoView(name: "Symbol_Black", size: 18)
                    .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 115))
            }
            .frame(width: 18, height: 18)
            Text("Bluejay Wispr")
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Theme.ink)
        }
    }
}

/// Sidebar footer: what the app is doing right now, with a breathing dot while live.
struct LiveStatus: View {
    let state: DictationController.State

    private var live: Bool { state != .idle }

    private var label: String {
        switch state {
        case .idle: return "Hold fn to dictate"
        case .recording(let locked): return locked ? "Locked — tap fn to finish" : "Listening"
        case .processing: return "Cleaning up"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !live)) { ctx in
                let beat = abs(sin(ctx.date.timeIntervalSinceReferenceDate * 2.6))
                Circle()
                    .fill(live ? Theme.blue : Theme.inkSubtle.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .scaleEffect(live ? 1 + 0.4 * beat : 1)
                    .opacity(live ? 0.65 + 0.35 * beat : 1)
            }
            .frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(live ? Theme.inkTertiary : Theme.inkSubtle)
                .contentTransition(.opacity)
        }
        .animation(.bjSoft, value: label)
    }
}

struct LogoView: View {
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
                .font(.system(size: size - 6))
                .foregroundStyle(Theme.blue)
        }
    }
}

/// Shared page scaffold: big title, optional subtitle, consistent padding.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 27, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
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

    var body: some View {
        Page(title: greeting, subtitle: "Hold fn to dictate. Double-tap to go hands-free.") {
            HStack(spacing: 12) {
                StatCard(value: "\(history.totalWords)", label: "Words")
                StatCard(value: averageWPM > 0 ? "\(averageWPM)" : "0", label: "Avg WPM")
                StatCard(value: "\(streakDays)", label: "Day streak")
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Recent")
                if history.entries.isEmpty {
                    EmptyHint(text: "Hold fn and say something.")
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
    let value: String
    let label: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 27, weight: .semibold))
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
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(Theme.blue)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(text)
                .font(.system(size: 13))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.blue)
                Spacer()
                // Timestamp gives way to the copy affordance on hover — the row itself is the button.
                Text(copied ? "Copied" : hovering ? "Click to copy" : Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.green : Theme.inkSubtle)
                    .contentTransition(.opacity)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            Text(entry.cleaned)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .lineLimit(showRaw ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showRaw, entry.raw != entry.cleaned {
                Text(entry.raw)
                    .font(.system(size: 12))
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
            "Notion", "Sentry", "Twilio", "Deepgram", "Wispr",
        ]),
    ]
}

struct DictionaryView: View {
    @ObservedObject var settings: AppSettings
    @State private var newWord = ""
    @State private var generateTopic = ""
    @State private var generating = false
    @State private var generateNote: String?
    private let cleaner = LLMCleaner()

    var body: some View {
        Page(title: "Dictionary", subtitle: "Words and names the recognizer should spell correctly.") {
            HStack(spacing: 8) {
                TextField("Add words, separated by commas", text: $newWord)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(fieldBackground)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .buttonStyle(CapsuleButtonStyle())
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Quick packs")
                WrapStack(spacing: 8) {
                    ForEach(VocabPacks.all, id: \.name) { pack in
                        let missing = missingCount(pack.terms)
                        Button {
                            withAnimation(.bjSnap) { settings.addDictionaryWords(pack.terms) }
                        } label: {
                            Text(missing > 0 ? "\(pack.name) +\(missing)" : "\(pack.name) ✓")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(missing > 0 ? Theme.blue : Theme.inkSubtle)
                                .contentTransition(.numericText())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(missing > 0 ? Theme.blueSoft : Theme.tableHeader))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(missing == 0)
                        .animation(.bjSoft, value: missing)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Or generate terms for a topic, like React Native or genomics", text: $generateTopic)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(fieldBackground)
                        .onSubmit(generate)
                    Button(action: generate) {
                        HStack(spacing: 5) {
                            if generating {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 11))
                            }
                            Text("Generate")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(generating ? Theme.inkSubtle : Theme.blue))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(generating)
                }
                if let generateNote {
                    Text(generateNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSubtle)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel("\(settings.dictionary.count) terms")
                    Spacer()
                    if settings.dictionary.count > 1 {
                        Button("Clear all") { settings.dictionary = [] }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                WrapStack(spacing: 8) {
                    ForEach(settings.dictionary, id: \.self) { word in
                        TagChip(word: word) {
                            withAnimation(.bjSnap) { settings.dictionary.removeAll { $0 == word } }
                        }
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .animation(.bjSnap, value: settings.dictionary)
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func missingCount(_ terms: [String]) -> Int {
        let existing = Set(settings.dictionary.map { $0.lowercased() })
        return terms.filter { !existing.contains($0.lowercased()) }.count
    }

    /// One field for one term or a whole list — commas and newlines both split.
    private func addWord() {
        settings.addDictionaryWords(
            newWord.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
        )
        newWord = ""
    }

    private func generate() {
        let topic = generateTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, !generating else { return }
        generating = true
        generateNote = nil
        Task { @MainActor in
            let terms = await cleaner.generateTerms(topic: topic)
            let before = settings.dictionary.count
            settings.addDictionaryWords(terms)
            let added = settings.dictionary.count - before
            generateNote = terms.isEmpty
                ? "No model available. Start LM Studio or check Settings."
                : "Added \(added) terms for \(topic)."
            if !terms.isEmpty { generateTopic = "" }
            generating = false
        }
    }
}

struct TagChip: View {
    let word: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hovering ? Theme.red : Theme.inkSubtle)
                    .frame(width: 17, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Capsule().fill(hovering ? Theme.surfaceActive : Theme.tableHeader))
        .scaleEffect(hovering ? 1.04 : 1)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
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

struct TeamView: View {
    @ObservedObject var settings: AppSettings
    @State private var newName = ""
    @State private var newRole = ""

    var body: some View {
        Page(title: "Team", subtitle: "Teammate names are added to the dictation vocabulary.") {
            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(addMember)
                TextField("Role (optional)", text: $newRole)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(addMember)
                Button("Add", action: addMember)
                    .buttonStyle(CapsuleButtonStyle())
            }

            if settings.teamMembers.isEmpty {
                EmptyHint(text: "Add the names you say in standups and reviews.")
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
            .fill(.white)
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
    let member: TeamMember
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.blueSoft)
                Text(String(member.name.prefix(1)).uppercased())
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.blue)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !member.role.isEmpty {
                    Text(member.role)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSubtle)
                }
            }
            Spacer()
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
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
