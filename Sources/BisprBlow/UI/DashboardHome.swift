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
            UpdateBanner()

            // One strip with hairlines between the figures: three tiles read as three buttons.
            HStack(spacing: 0) {
                StatCard(value: "\(history.totalWords)", label: "Words")
                StatDivider()
                StatCard(value: "\(averageWPM)", label: "Words per minute")
                StatDivider()
                StatCard(value: "\(streakDays)", label: "Day streak")
            }
            .card(padding: 18)

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

// A newer release exists. One line, on the page they already open, and only while it is true —
// an update is something the user can act on, so it gets UI, while which version they run and where
// it came from is not, so there is no section for it beyond the off switch in Settings.
struct UpdateBanner: View {
    var themeID = Appearance.current
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        if let latest = checker.latest {
            Button { NSWorkspace.shared.open(UpdateChecker.releasePage) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .font(.bj(12))
                        .foregroundStyle(Theme.blue)
                    Text("BisprBlow \(latest) is out")
                        .font(.bj(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("Get it on GitHub")
                        .font(.bj(12))
                        .foregroundStyle(Theme.inkSubtle)
                    Spacer()
                }
                .card()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .transition(.offset(y: -6).combined(with: .opacity))
            .animation(.bjSoft, value: latest)
        }
    }
}

struct StatCard: View {
    var themeID = Appearance.current
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.bj(32, weight: .bold))
                .monospacedDigit()
                .tracking(-0.8)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())   // digits roll as stats update
                .animation(.bjSoft, value: value)
            Text(label)
                .font(.bj(12))
                .foregroundStyle(Theme.inkSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}

private struct StatDivider: View {
    var themeID = Appearance.current

    var body: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.6))
            .frame(width: 1, height: 40)
            .padding(.trailing, 18)
    }
}

struct EmptyHint: View {
    var themeID = Appearance.current
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.bj(13, weight: .medium))
                .foregroundStyle(Theme.blue)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.blueSoft))
            Text(text)
                .font(.bj(13))
                .foregroundStyle(Theme.inkTertiary)
        }
        .card(padding: 18)
    }
}
