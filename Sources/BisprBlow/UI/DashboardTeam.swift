import AppKit
import SwiftUI

// MARK: - Team

// Team is the cloud page, so it is behind sign-in, which puts a door in front of the local name
// list. The `CloudConfig.ready` branch keeps that honest: a build with no project configured has no
// sign-in to pass, so gating there would delete the name list rather than hide it. Normal builds
// never take that path — the project is compiled in.
struct TeamPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var cloud: CloudClient

    var body: some View {
        if !CloudConfig.ready {
            TeamView(settings: settings)
        } else if cloud.session == nil {
            Page(title: "Team", subtitle: "Sign in to join your team.") {
                SignInView(cloud: cloud, showsBlurb: false)
                    .card(padding: Metric.cardPad)
            }
        } else {
            TeamView(settings: settings, cloud: cloud)
        }
    }
}

struct TeamView: View {
    @ObservedObject var settings: AppSettings
    // nil in a build with no project configured, where there is no cloud team to show.
    var cloud: CloudClient?
    // Re-renders this page when the team changes; `cloud` is this same shared object, which a
    // plain `var` would not observe.
    @ObservedObject private var live = CloudClient.shared
    @State private var newName = ""
    @State private var newRole = ""

    private var inTeam: Bool { cloud != nil && live.org != nil }

    var body: some View {
        // What it does, not how it works: a name you say out loud comes back spelled wrong until it
        // is in here.
        Page(title: "Team", subtitle: inTeam ? "Your teammates and the words they've added."
                                              : "Names you add here get spelled right.") {
            if let cloud {
                TeamCloudSection(cloud: cloud)
                    .card(padding: Metric.cardPad)
            }
            if let cloud, inTeam {
                RosterSection(cloud: cloud, settings: settings)
            } else {
                localNames
            }
        }
    }

    @ViewBuilder
    private var localNames: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Members")
            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .bjField()
                    .frame(maxWidth: .infinity)
                    .onSubmit(addMember)
                TextField("Role (optional)", text: $newRole)
                    .bjField()
                    .frame(maxWidth: .infinity)
                    .onSubmit(addMember)
                Button("Add", action: addMember)
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        if settings.teamMembers.isEmpty {
            EmptyHint(text: "No names yet")
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

// The team's roster, read from the server. Nothing to type: people appear when they join.
struct RosterSection: View {
    @ObservedObject var cloud: CloudClient
    @ObservedObject var settings: AppSettings
    @State private var note: String?
    @State private var loaded = false
    @State private var reloadTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Members")
            if let note {
                HStack(spacing: 10) {
                    EmptyHint(text: note)
                    Button("Try again") { reloadTick += 1 }
                        .buttonStyle(QuietButtonStyle())
                }
            } else if cloud.roster.isEmpty {
                EmptyHint(text: loaded ? "No members yet" : "Loading members")
            } else {
                VStack(spacing: 6) {
                    ForEach(cloud.roster) { member in
                        MemberRow(member: member, isMe: member.userID == cloud.session?.userID,
                                  cloud: cloud, settings: settings)
                    }
                }
            }
        }
        .task(id: "\(cloud.org?.id.uuidString ?? "")-\(reloadTick)") {
            loaded = false
            do {
                try await cloud.refreshRoster()
                note = nil
                loaded = true
            } catch {
                logLine("roster load failed: \(error.localizedDescription)")
                note = "Couldn't load members."
            }
        }
    }
}

// A teammate. Their dictionary opens in the row, and words can be copied into yours.
struct MemberRow: View {
    var themeID = Appearance.current
    let member: OrgMember
    let isMe: Bool
    @ObservedObject var cloud: CloudClient
    @ObservedObject var settings: AppSettings
    @State private var open = false
    @State private var words: [String]?
    @State private var loading = false
    @State private var note: String?
    @State private var picked: Set<String> = []

    private var mine: Set<String> { Set(settings.dictionary.map { $0.lowercased() }) }
    private var fresh: [String] { DictionaryWords.importable(theirs: words ?? [], mine: settings.dictionary) }
    private var chosen: [String] { fresh.filter { picked.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                InitialCircle(letter: String(member.displayName.prefix(1)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .font(.bj(TypeSize.body, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        if member.isOwner {
                            Text("Owner")
                                .font(.bj(TypeSize.micro, weight: .medium))
                                .foregroundStyle(Theme.inkSubtle)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.surfaceActive))
                        }
                    }
                    if let email = member.email, !email.isEmpty {
                        Text(email)
                            .font(.bj(TypeSize.micro))
                            .foregroundStyle(Theme.inkSubtle)
                    }
                }
                Spacer()
                if !isMe {
                    Button(open ? "Hide words" : "Their words", action: toggle)
                        .buttonStyle(QuietButtonStyle())
                }
            }
            if open {
                panel
                    .transition(.opacity)
            }
        }
        .card(padding: Metric.rowPad)
        .animation(.bjSoft, value: open)
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let note {
                HStack(spacing: 10) {
                    Text(note)
                        .font(.bj(TypeSize.micro))
                        .foregroundStyle(Theme.red)
                    Button("Try again") { reload() }
                        .buttonStyle(QuietButtonStyle())
                }
            } else if let words, words.isEmpty {
                Text("No words yet")
                    .font(.bj(TypeSize.caption))
                    .foregroundStyle(Theme.inkSubtle)
            } else if let words {
                WrapStack(spacing: 6) {
                    ForEach(words, id: \.self) { word in chip(word) }
                }
                HStack(spacing: 8) {
                    Button("Add selected") { add(chosen) }
                        .buttonStyle(CapsuleButtonStyle())
                        .disabled(chosen.isEmpty)
                    Button("Add all \(fresh.count)") { add(fresh) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(fresh.isEmpty)
                }
            }
        }
    }

    private func chip(_ word: String) -> some View {
        let have = mine.contains(word.lowercased())
        let on = picked.contains(word)
        return Button {
            if on { picked.remove(word) } else { picked.insert(word) }
        } label: {
            Text(word)
                .font(.bj(TypeSize.caption))
                .foregroundStyle(have ? Theme.inkSubtle : (on ? Theme.accentText : Theme.ink))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(on && !have ? Theme.blueSoft : Theme.surfaceActive.opacity(have ? 0.5 : 1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .handCursor(!have)
        .disabled(have)
        .help(have ? "Already in your dictionary" : "")
    }

    private func toggle() {
        open.toggle()
        guard open, words == nil, !loading else { return }
        reload()
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        note = nil
        Task { @MainActor in
            do {
                words = DictionaryWords.clean(try await cloud.dictionaryWords(of: member.userID))
            } catch {
                logLine("member words load failed: \(error.localizedDescription)")
                note = "Couldn't load their words."
            }
            loading = false
        }
    }

    private func add(_ list: [String]) {
        withAnimation(.bjSnap) {
            settings.addDictionaryWords(list)
            picked.subtract(list)
        }
    }
}

struct TeamRow: View {
    var themeID = Appearance.current
    let member: TeamMember
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            InitialCircle(letter: String(member.name.prefix(1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.bj(TypeSize.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !member.role.isEmpty {
                    Text(member.role)
                        .font(.bj(TypeSize.micro))
                        .foregroundStyle(Theme.inkSubtle)
                }
            }
            Spacer()
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.bj(TypeSize.micro))
                        .foregroundStyle(Theme.red)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("Remove \(member.name)")
            }
        }
        .card(padding: Metric.rowPad)
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}
