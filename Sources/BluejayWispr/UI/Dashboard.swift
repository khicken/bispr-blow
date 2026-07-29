import AppKit
import SwiftUI

/// Main window ("Hub"): sidebar navigation + content pane, Bluejay-themed.
final class DashboardWindowController {
    private var window: NSWindow?
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
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
            win.contentView = NSHostingView(rootView: DashboardView(controller: controller))
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
    }

    @ObservedObject var controller: DictationController
    @StateObject private var history = HistoryStore.shared
    @StateObject private var settings = AppSettings.shared
    @State private var section: Section = .home

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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                LogoView(name: "Symbol_Black", size: 20)
                Text("Bluejay Wispr")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 20)

            ForEach(Section.allCases) { item in
                SidebarItem(item: item, selected: section == item) { section = item }
            }

            Spacer()

            Text("Hold fn to dictate")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSubtle)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
        .frame(width: 192)
        .background(Theme.surface)
    }

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
        .transition(.opacity)
        .animation(.easeOut(duration: 0.12), value: section)
    }
}

struct SidebarItem: View {
    let item: DashboardView.Section
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.surfaceActive : (hovering ? Theme.surfaceActive.opacity(0.5) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
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
                content()
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
                        }
                    }
                }
            }
        }
    }
}

struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 27, weight: .semibold))
                .monospacedDigit()
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            SectionLabel(label)
        }
        .card()
    }
}

struct EmptyHint: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(Theme.blue)
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
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: DictationEntry
    var showRaw = false
    @State private var copied = false
    @State private var expanded = false
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
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSubtle)
                if hovering || copied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.cleaned, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Theme.green : Theme.inkSubtle)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            Text(entry.cleaned)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .lineLimit(expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showRaw, expanded, entry.raw != entry.cleaned {
                Text(entry.raw)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(padding: 13)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
        .onHover { hovering = $0 }
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
    @State private var bulkText = ""
    @State private var showBulk = false
    @State private var generateTopic = ""
    @State private var generating = false
    @State private var generateNote: String?
    private let cleaner = LLMCleaner()

    var body: some View {
        Page(title: "Dictionary", subtitle: "Words and names the recognizer should spell correctly.") {
            HStack(spacing: 8) {
                TextField("Add a word or phrase", text: $newWord)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(fieldBackground)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .buttonStyle(CapsuleButtonStyle())
                Button("Bulk add") {
                    withAnimation(.easeOut(duration: 0.15)) { showBulk.toggle() }
                }
                .buttonStyle(CapsuleButtonStyle(filled: false))
                Spacer()
                Toggle(isOn: $settings.injectDictionary) {
                    Text("Use in cleanup")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Corrects mishears like \"work tree\" to \"worktree\" during cleanup")
            }

            if showBulk {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $bulkText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 90)
                        .background(fieldBackground)
                    HStack {
                        Text("Separate terms with commas or newlines.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSubtle)
                        Spacer()
                        Button("Import") {
                            let words = bulkText
                                .split(whereSeparator: { $0 == "," || $0.isNewline })
                                .map(String.init)
                            settings.addDictionaryWords(words)
                            bulkText = ""
                            withAnimation(.easeOut(duration: 0.15)) { showBulk = false }
                        }
                        .buttonStyle(CapsuleButtonStyle())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Quick packs")
                WrapStack(spacing: 8) {
                    ForEach(VocabPacks.all, id: \.name) { pack in
                        let missing = missingCount(pack.terms)
                        Button {
                            settings.addDictionaryWords(pack.terms)
                        } label: {
                            Text(missing > 0 ? "\(pack.name) +\(missing)" : "\(pack.name) ✓")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(missing > 0 ? Theme.blue : Theme.inkSubtle)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(missing > 0 ? Theme.blueSoft : Theme.tableHeader))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(missing == 0)
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
                            settings.dictionary.removeAll { $0 == word }
                        }
                    }
                }
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

    private func addWord() {
        settings.addDictionaryWords([newWord])
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
        .onHover { hovering = $0 }
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
                            settings.teamMembers.removeAll { $0.id == member.id }
                        }
                    }
                }
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
        settings.teamMembers.append(TeamMember(name: name, role: newRole.trimmingCharacters(in: .whitespaces)))
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
