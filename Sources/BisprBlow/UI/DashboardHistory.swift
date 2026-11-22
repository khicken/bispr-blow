import AppKit
import SwiftUI

// MARK: - History

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        Page(title: "History") {
            if history.entries.isEmpty {
                EmptyHint(text: "No dictations yet. \(AppSettings.shared.holdHint).")
            } else {
                HStack {
                    SectionLabel(history.entries.count == 1 ? "1 dictation" : "\(history.entries.count) dictations")
                    Spacer()
                    Button("Clear all") { confirmClear = true }
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
        .alert("Clear all dictations?", isPresented: $confirmClear) {
            Button("Clear all", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
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
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    // Time today, "Yesterday", else a short date: short and steady, so the row does not reflow.
    private static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.appName.isEmpty ? "Unknown app" : entry.appName)
                    .font(.bj(TypeSize.micro, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                Spacer()
                // Timestamp gives way to the copy affordance on hover — the row itself is the button.
                Text(copied ? "Copied" : Self.stamp(entry.date))
                    .font(.bj(TypeSize.micro))
                    .foregroundStyle(copied ? Theme.green : Theme.inkTertiary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
                    .contentTransition(.opacity)
                // A fixed slot, so showing the icon on hover moves nothing.
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.bj(TypeSize.micro, weight: copied ? .bold : .regular))
                    .foregroundStyle(copied ? Theme.green : Theme.inkTertiary)
                    .frame(width: 14)
                    .opacity(copied || hovering ? 1 : 0)
            }
            Text(entry.cleaned)
                .font(.bj(TypeSize.body))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .lineLimit(showRaw ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showRaw, entry.raw != entry.cleaned {
                Text(entry.raw)
                    .font(.bj(TypeSize.caption))
                    .foregroundStyle(Theme.inkSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(padding: Metric.rowPad)
        .background(
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .fill(Theme.surfaceActive.opacity(hovering ? 0.5 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .stroke(Theme.green.opacity(copied ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .handCursor()
        .scaleEffect(copied ? 0.99 : 1)
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
