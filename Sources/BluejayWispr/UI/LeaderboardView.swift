import SwiftUI

/// The team's dictation, ranked — words, pace, and streaks, built entirely from counts. The
/// board never sees anyone's text; that is a property of the database, not of this view.
struct LeaderboardView: View {
    @ObservedObject var cloud: CloudClient

    @State private var period: Period = .week
    @State private var rows: [LeaderboardRow] = []
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var note: String?

    enum Period: String, CaseIterable, Identifiable {
        case day, week, month, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .day: "Today"
            case .week: "This week"
            case .month: "This month"
            case .all: "All time"
            }
        }

        var emptyPhrase: String {
            switch self {
            case .day: "today"
            case .week: "this week"
            case .month: "this month"
            case .all: "yet"
            }
        }
    }

    var body: some View {
        Page(title: "Leaderboard", subtitle: cloud.org?.name) {
            if !CloudConfig.ready {
                EmptyHint(text: "Teams aren't switched on in this build.")
            } else if cloud.session == nil {
                EmptyHint(text: "Sign in from Settings to share a leaderboard with your team.")
            } else if cloud.org == nil {
                EmptyHint(text: "Create or join a team in Settings. Joining is what puts you on the board.")
            } else {
                picker
                board
            }
        }
        .task(id: period) { await reload() }
    }

    private var picker: some View {
        HStack(spacing: 8) {
            ForEach(Period.allCases) { candidate in
                let selected = candidate == period
                Button {
                    withAnimation(.bjSnap) { period = candidate }
                } label: {
                    Text(candidate.label)
                        .font(.bj(12, weight: .medium))
                        .foregroundStyle(selected ? Theme.blue : Theme.inkSubtle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(selected ? Theme.blueSoft : Theme.tableHeader))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var board: some View {
        if let note {
            EmptyHint(text: note)
        } else if rows.isEmpty && loadedOnce && !loading {
            EmptyHint(text: "Nothing on the board \(period.emptyPhrase). \(AppSettings.shared.holdHint).")
        } else {
            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    LeaderRow(rank: index + 1, row: row,
                              isMe: row.userID == cloud.session?.userID)
                        .transition(.opacity)
                }
            }
            .animation(.bjSnap, value: rows.map(\.id))
        }
    }

    private func reload() async {
        guard CloudConfig.ready, cloud.session != nil else { return }
        if cloud.org == nil { await cloud.refreshOrg() }
        guard cloud.org != nil else { return }
        loading = true
        do {
            rows = try await cloud.leaderboard(period: period.rawValue)
            note = nil
        } catch {
            note = error.localizedDescription
        }
        loading = false
        loadedOnce = true
    }
}

/// One member. Your own row wears the accent so it is findable at a glance.
private struct LeaderRow: View {
    var themeID = Appearance.current
    let rank: Int
    let row: LeaderboardRow
    let isMe: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.bj(13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(rank == 1 ? Theme.blue : Theme.inkSubtle)
                .frame(width: 22, alignment: .center)
            ZStack {
                Circle().fill(Theme.blueSoft)
                Text(String(row.displayName.prefix(1)).uppercased())
                    .font(.bj(12.5, weight: .semibold))
                    .foregroundStyle(Theme.blue)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(isMe ? "\(row.displayName) (you)" : row.displayName)
                    .font(.bj(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let wpm = row.wpm {
                    Text("\(Int(wpm)) words a minute")
                        .font(.bj(11))
                        .foregroundStyle(Theme.inkSubtle)
                }
            }
            Spacer()
            if row.dayStreak > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.bj(10.5))
                    Text("\(row.dayStreak)")
                        .font(.bj(12, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.red)
                .help("\(row.dayStreak) days in a row")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.words.formatted())
                    .font(.bj(15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("words")
                    .font(.bj(11))
                    .foregroundStyle(Theme.inkSubtle)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isMe ? Theme.blueSoft : Theme.tableHeader))
        .scaleEffect(hovering ? 1.008 : 1)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}
