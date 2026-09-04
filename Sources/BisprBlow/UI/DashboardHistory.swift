import AppKit
import SwiftUI

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
