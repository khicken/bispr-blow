import AppKit
import SwiftUI

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

    // Names the user's own binding: "fn" stops being the answer the moment they rebind it.
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
