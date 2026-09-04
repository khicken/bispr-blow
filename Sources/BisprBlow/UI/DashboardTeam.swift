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
    // nil in a build with no project configured, where there is no cloud team to show.
    var cloud: CloudClient?
    @State private var newName = ""
    @State private var newRole = ""

    var body: some View {
        // What it does, not how it works: a teammate list is worth having because a name you say out
        // loud comes back spelled wrong until it is in here.
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
                // The state, then the control, like the Dictionary page's empty hint. The subtitle
                // above already carries the why.
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
