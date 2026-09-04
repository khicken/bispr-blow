import AppKit
import SwiftUI

// MARK: - Dictionary

// Curated one-click vocabulary packs.
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

    // Search and sort only exist once the list is long enough to need them.
    private var listIsLong: Bool { settings.dictionary.count > 8 }

    // Typed text that is one topic rather than a list of words — the only case where "add everything
    // about this" means anything.
    private var topic: String? {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, !trimmed.contains(",") else { return nil }
        return trimmed
    }

    // What the list shows: search narrows, the toggle orders. `dictionary` is stored in the order
    // terms were added, so newest-first is the reverse.
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

    // What the page is for, said once, and dismissible. The chips are the user's own terms rather
    // than samples, which is what makes the point immediately.
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
                // Terms only, no action: the field to add one sits directly below this panel.
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

    // A brand render where the theme has one, the app icon's gradient where it does not — the same
    // dark field the pill uses. The scrim keeps white text readable, darkest where the text is.
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

    // One field, always visible, and the page's only place to type. Adding words is the job; a topic
    // is a shortcut for adding thirty at once, so the same text feeds both verbs and the second
    // spells out what it will do with what you typed.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a word or a name, or several separated by commas", text: $newWord)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .onSubmit(addWord)
                // Return adds the literal words. Asking a model for thirty terms is slower to do by
                // accident, so it costs a click.
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

    // A flat divided list, not chips: a pack adds thirty terms at once, and thirty capsules in a
    // wrapping grid is a pile — nothing to scan down, and nowhere to put a search field.
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
                // The list scrolls inside itself rather than making the page grow: thirty terms in a
                // page-height list pushed the search field and the packs off the window. Fixed
                // height, because past the threshold there is always more content than fits.
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

    // Last, and quiet: packs fill an empty list on day one. They are also the only path that needs
    // no typing, which is why they stay on the page rather than folding into the field above.
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

    // One field for one term or a whole list — commas and newlines both split.
    private func addWord() {
        let before = settings.dictionary
        withAnimation(.bjSnap) {
            settings.addDictionaryWords(
                newWord.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
            )
        }
        // Say something only when nothing happened: the term appearing in the list is the
        // confirmation. Compared as arrays, not counts — a case-only re-add changes a term without
        // changing the count.
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

// One term. Removal is the only action, and it appears on hover: a list of a hundred terms should
// read as words, not as buttons.
struct TermRow: View {
    var themeID = Appearance.current
    let word: String
    let first: Bool
    // Extra room on the right for the overlay scrollbar, which otherwise draws over the remove
    // button. Only the scrolling list passes it; the divider stays full width either way.
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
                // A trash bin rather than an ✕: ✕ is dismiss, and this deletes a saved word. Full row
                // height and wide enough to hit without aiming.
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
            // The button is taller than the old one, so the row keeps its height from the button
            // rather than gaining eight points of padding.
            .padding(.vertical, 4)
            .frame(minHeight: 38)
        }
        // Full strength, not 60%: the row under the pointer is the one about to lose a term.
        .background(hovering ? Theme.surfaceActive : .clear)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
        .transition(.opacity)
    }
}

// Left-aligned wrapping flow layout (chips/tags grid).
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
