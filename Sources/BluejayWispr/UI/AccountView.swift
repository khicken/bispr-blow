import AppKit
import SwiftUI

/// The Account group in Settings: sign in with an emailed code, your team, and the two backup
/// switches. Signed out, the app is exactly what it was — everything here is additive.
struct AccountSection: View {
    @ObservedObject var cloud: CloudClient
    @ObservedObject var settings: AppSettings

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var note: String?

    @State private var teamName = ""
    @State private var joinCode = ""
    @State private var inviteEmail = ""
    @State private var inviteCode: String?
    @State private var inviteFor = ""
    @State private var codeCopied = false
    @State private var memberNames: [String] = []

    var body: some View {
        Group {
            if cloud.session == nil {
                signIn
            } else {
                account
            }
        }
        .task(id: cloud.session?.userID) {
            guard cloud.session != nil else { return }
            await cloud.refreshOrg()
            await loadMembers()
        }
    }

    // MARK: - Signed out

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to back up your stats and share a leaderboard with your team.")
                .font(.bj(12))
                .foregroundStyle(Theme.inkSubtle)
            HStack(spacing: 8) {
                TextField("you@company.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 260)
                    .onSubmit(submitSignIn)
                if codeSent {
                    TextField("Code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.bj(13))
                        .monospacedDigit()
                        .padding(10)
                        .background(fieldBackground)
                        .frame(width: 100)
                        .onSubmit(submitSignIn)
                        .transition(.opacity)
                }
                Button(codeSent ? "Sign in" : "Email me a code", action: submitSignIn)
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(busy || trimmedEmail.isEmpty
                              || (codeSent && code.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            if codeSent {
                Text("Check \(trimmedEmail) for a code.")
                    .font(.bj(11.5))
                    .foregroundStyle(Theme.inkSubtle)
            }
            noteLine
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .animation(.bjSoft, value: codeSent)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func submitSignIn() {
        guard !busy, !trimmedEmail.isEmpty else { return }
        run {
            if codeSent {
                try await cloud.signIn(email: trimmedEmail,
                                       code: code.trimmingCharacters(in: .whitespaces))
                await loadMembers()
                code = ""
                codeSent = false
            } else {
                try await cloud.requestCode(email: trimmedEmail)
                codeSent = true
            }
        }
    }

    // MARK: - Signed in

    private var account: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                initialCircle(String(cloud.session?.email.prefix(1) ?? "?"))
                Text(cloud.session?.email ?? "")
                    .font(.bj(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Sign out") {
                    Task { await cloud.signOut() }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            divider

            if let org = cloud.org {
                team(org)
            } else {
                joinOrCreate
            }

            divider

            ToggleRow("Back up dictation stats",
                      help: "Word counts and timings sync to your account, and count toward your team's leaderboard. Never the words themselves.",
                      isOn: $settings.syncStats)
            if settings.syncStats {
                ToggleRow("Include what you said",
                          help: "Keeps the text of each dictation with your account too. Only you can read it — teammates never see it.",
                          isOn: $settings.syncTexts)
            }
        }
        .animation(.bjSoft, value: settings.syncStats)
    }

    private var joinOrCreate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A team shares a leaderboard of word counts — never of words. Joining one is what puts you on it.")
                .font(.bj(12))
                .foregroundStyle(Theme.inkSubtle)
            HStack(spacing: 8) {
                TextField("Team name", text: $teamName)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(createTeam)
                Button("Create a team", action: createTeam)
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                    .disabled(busy || teamName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 8) {
                TextField("Invite code", text: $joinCode)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(fieldBackground)
                    .frame(maxWidth: 220)
                    .onSubmit(joinTeam)
                Button("Join", action: joinTeam)
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                    .disabled(busy || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            noteLine
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }

    private func team(_ org: CloudOrg) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                initialCircle(String(org.name.prefix(1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(org.name)
                        .font(.bj(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if !memberNames.isEmpty {
                        Text(memberNames.joined(separator: ", "))
                            .font(.bj(11))
                            .foregroundStyle(Theme.inkSubtle)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            if org.isOwner {
                HStack(spacing: 8) {
                    TextField("Teammate's email", text: $inviteEmail)
                        .textFieldStyle(.plain)
                        .font(.bj(13))
                        .padding(10)
                        .background(fieldBackground)
                        .frame(maxWidth: 260)
                        .onSubmit(invite)
                    Button("Invite", action: invite)
                        .buttonStyle(CapsuleButtonStyle(filled: false))
                        .disabled(busy || inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let inviteCode {
                    // The row is the copy button, like history rows.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inviteCode, forType: .string)
                        withAnimation(.bjSnap) { codeCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(.bjSoft) { codeCopied = false }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(inviteCode)
                                .font(.bj(13, weight: .semibold))
                                .monospaced()
                                .foregroundStyle(Theme.ink)
                            Text("for \(inviteFor) — send it to them yourself")
                                .font(.bj(12))
                                .foregroundStyle(Theme.inkSubtle)
                            Spacer()
                            Text(codeCopied ? "Copied" : "Click to copy")
                                .font(.bj(11))
                                .foregroundStyle(codeCopied ? Theme.green : Theme.inkSubtle)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceActive.opacity(0.6)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .transition(.opacity)
                }
            }
            noteLine
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .animation(.bjSoft, value: inviteCode)
    }

    // MARK: - Actions

    private func createTeam() {
        let name = teamName.trimmingCharacters(in: .whitespaces)
        guard !busy, !name.isEmpty else { return }
        run {
            try await cloud.createOrg(named: name)
            teamName = ""
            await loadMembers()
        }
    }

    private func joinTeam() {
        let code = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !busy, !code.isEmpty else { return }
        run {
            try await cloud.joinOrg(code: code)
            joinCode = ""
            await loadMembers()
        }
    }

    private func invite() {
        let address = inviteEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !busy, !address.isEmpty else { return }
        run {
            inviteCode = try await cloud.createInvite(email: address)
            inviteFor = address
            inviteEmail = ""
        }
    }

    private func loadMembers() async {
        memberNames = (try? await cloud.members().map(\.displayName)) ?? []
    }

    /// One shape for every async action: clear the note, show the error if there is one.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        note = nil
        Task { @MainActor in
            do { try await work() } catch { note = error.localizedDescription }
            busy = false
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            Text(note)
                .font(.bj(11.5))
                .foregroundStyle(Theme.red)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
    }

    private func initialCircle(_ letter: String) -> some View {
        ZStack {
            Circle().fill(Theme.blueSoft)
            Text(letter.uppercased())
                .font(.bj(12.5, weight: .semibold))
                .foregroundStyle(Theme.blue)
        }
        .frame(width: 28, height: 28)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
