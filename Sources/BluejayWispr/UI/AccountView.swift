import AppKit
import SwiftUI

/// The Account group in Settings: who is signed in, and the two backup switches. Teams are not
/// here — they are the Team page, which is the only place they are, because an invite form in two
/// places is two invite forms to keep in step.
struct AccountSection: View {
    @ObservedObject var cloud: CloudClient
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            if cloud.session == nil {
                SignInView(cloud: cloud)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
            } else {
                account
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                InitialCircle(letter: String(cloud.session?.email.prefix(1) ?? "?"))
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

            CardDivider()

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
}

/// The cloud half of the Team page: the org you are in, who else is in it, and the invite codes if
/// you own it. Lifted out of Settings when Team became the place teams live.
struct TeamCloudSection: View {
    var themeID = Appearance.current
    @ObservedObject var cloud: CloudClient

    @State private var teamName = ""
    @State private var joinCode = ""
    @State private var inviteEmail = ""
    @State private var inviteCode: String?
    @State private var inviteFor = ""
    @State private var codeCopied = false
    @State private var memberNames: [String] = []
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        Group {
            if let org = cloud.org {
                team(org)
            } else {
                joinOrCreate
            }
        }
        .task(id: cloud.session?.userID) {
            guard cloud.session != nil else { return }
            await cloud.refreshOrg()
            await loadMembers()
        }
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
                    .background(FieldBackground())
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
                    .background(FieldBackground())
                    .frame(maxWidth: 220)
                    .onSubmit(joinTeam)
                Button("Join", action: joinTeam)
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                    .disabled(busy || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            noteLine
        }
    }

    private func team(_ org: CloudOrg) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                InitialCircle(letter: String(org.name.prefix(1)))
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
                        .background(FieldBackground())
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

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            Text(note)
                .font(.bj(11.5))
                .foregroundStyle(Theme.red)
        }
    }
}

/// The initial of an address or a team name, in a soft circle.
struct InitialCircle: View {
    var themeID = Appearance.current
    let letter: String

    var body: some View {
        ZStack {
            Circle().fill(Theme.blueSoft)
            Text(letter.uppercased())
                .font(.bj(12.5, weight: .semibold))
                .foregroundStyle(Theme.blue)
        }
        .frame(width: 28, height: 28)
    }
}

/// The hairline between rows of one card.
struct CardDivider: View {
    var themeID = Appearance.current

    var body: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
    }
}

struct FieldBackground: View {
    var themeID = Appearance.current

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

/// Signing in, in one place — Settings shows it inside the Account group, the Team page shows it
/// as the whole page. Two copies of this drifted apart the moment either was touched.
///
/// It says "sign in or create an account" because that is literally one call: `requestCode` passes
/// `create_user: true`, so a first-time address and a returning one take the same path and there is
/// no sign-up form to build.
struct SignInView: View {
    var themeID = Appearance.current
    @ObservedObject var cloud: CloudClient
    /// Team fills the page, Settings sits in a card — the difference is only the copy above.
    var showsBlurb = true

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsBlurb {
                Text("Sign in or create an account to back up your stats and share a leaderboard with your team.")
                    .font(.bj(12))
                    .foregroundStyle(Theme.inkSubtle)
            }
            HStack(spacing: 8) {
                TextField("you@company.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.bj(13))
                    .padding(10)
                    .background(FieldBackground())
                    .frame(maxWidth: 260)
                    .onSubmit(submit)
                if codeSent {
                    TextField("Code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.bj(13))
                        .monospacedDigit()
                        .padding(10)
                        .background(FieldBackground())
                        .frame(width: 100)
                        .onSubmit(submit)
                        .transition(.opacity)
                }
                Button(codeSent ? "Sign in" : "Email me a code", action: submit)
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(busy || trimmedEmail.isEmpty
                              || (codeSent && code.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            if codeSent {
                Text("Check \(trimmedEmail) for a code.")
                    .font(.bj(11.5))
                    .foregroundStyle(Theme.inkSubtle)
            }
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border.opacity(0.6)).frame(width: 34, height: 1)
                Text("or")
                    .font(.bj(11))
                    .foregroundStyle(Theme.inkTertiary)
                Rectangle().fill(Theme.border.opacity(0.6)).frame(width: 34, height: 1)
            }
            Button(action: google) {
                HStack(spacing: 7) {
                    GoogleMark()
                    Text("Continue with Google")
                }
            }
            .buttonStyle(CapsuleButtonStyle(filled: false))
            .disabled(busy)
            if let note {
                Text(note)
                    .font(.bj(11.5))
                    .foregroundStyle(Theme.red)
            }
        }
        .animation(.bjSoft, value: codeSent)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func submit() {
        guard !busy, !trimmedEmail.isEmpty else { return }
        run {
            if codeSent {
                try await cloud.signIn(email: trimmedEmail,
                                       code: code.trimmingCharacters(in: .whitespaces))
                code = ""
                codeSent = false
            } else {
                try await cloud.requestCode(email: trimmedEmail)
                codeSent = true
            }
        }
    }

    private func google() {
        guard !busy else { return }
        run { try await cloud.signInWithGoogle() }
    }

    /// Closing the Google sheet is a decision, not a failure, so it leaves no red line behind.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        note = nil
        Task { @MainActor in
            do { try await work() }
            catch is CancellationError {}
            catch { note = error.localizedDescription }
            busy = false
        }
    }

}

/// Google's G. Drawn rather than shipped as an asset: it is four fixed brand colours and a few
/// paths, and Google's guidelines require the mark unmodified — which a tinted SF Symbol would not
/// be. These four hexes are Google's own, so they are not palette tokens and must not become them.
private struct GoogleMark: View {
    var body: some View {
        ZStack {
            Circle().fill(.white)
            Text("G")
                .font(.system(size: 10.5, weight: .bold, design: .default))
                .foregroundStyle(Color(red: 0.259, green: 0.522, blue: 0.957))
        }
        .frame(width: 15, height: 15)
        .overlay(Circle().stroke(Theme.border.opacity(0.5), lineWidth: 0.5))
    }
}
