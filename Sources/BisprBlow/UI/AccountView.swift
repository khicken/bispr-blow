import AppKit
import SwiftUI

// The Account group in Settings: who is signed in, and the two backup switches. Teams live on the
// Team page and only there — an invite form in two places is two invite forms to keep in step.
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
                      help: "Syncs word counts for your team, never your words.",
                      isOn: $settings.syncStats)
            if settings.syncStats {
                ToggleRow("Back up dictation text",
                          help: "Saves your dictations. Only you can see them.",
                          isOn: $settings.syncTexts)
            }
        }
        .animation(.bjSoft, value: settings.syncStats)
    }
}

// The cloud half of the Team page: the org you are in, who else is in it, and the invite codes if
// you own it. Lifted out of Settings when Team became the place teams live.
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
    @State private var creating = false
    @State private var busy: Action?
    @State private var note: String?

    private enum Action { case create, join, invite }

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

    // One form at a time: joining is the common case, so starting a team is the quiet link.
    private var joinOrCreate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(creating ? "Start a team" : "Join your team")
                .font(.bj(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                if creating {
                    field("Team name", text: $teamName, submit: createTeam)
                    Button(action: createTeam) { label("Create", for: .create) }
                        .buttonStyle(CapsuleButtonStyle())
                        .disabled(busy != nil || teamName.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    field("Invite code", text: $joinCode, submit: joinTeam)
                    Button(action: joinTeam) { label("Join", for: .join) }
                        .buttonStyle(CapsuleButtonStyle())
                        .disabled(busy != nil || joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Button(creating ? "Join with a code" : "Start a new team") {
                withAnimation(.bjSnap) {
                    creating.toggle()
                    note = nil
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(busy != nil)
            // Puts the text, not the hover fill, on the field's left edge.
            .padding(.leading, -8)
            noteLine
        }
    }

    private func team(_ org: CloudOrg) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                InitialCircle(letter: String(org.name.prefix(1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(org.name)
                        .font(.bj(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if !memberNames.isEmpty {
                        Text(memberNames.joined(separator: ", "))
                            .font(.bj(12))
                            .foregroundStyle(Theme.inkSubtle)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            if org.isOwner {
                HStack(spacing: 8) {
                    field("Teammate's email", text: $inviteEmail, width: 260, submit: invite)
                    Button(action: invite) { label("Invite", for: .invite) }
                        .buttonStyle(CapsuleButtonStyle(filled: false))
                        .disabled(busy != nil || inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty)
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
                        HStack(spacing: 10) {
                            Text(inviteCode)
                                .font(.bj(14, weight: .semibold))
                                .monospaced()
                                .foregroundStyle(Theme.ink)
                            Text("Send this to \(inviteFor)")
                                .font(.bj(12))
                                .foregroundStyle(Theme.inkSubtle)
                            Spacer()
                            Text(codeCopied ? "Copied" : "Copy")
                                .font(.bj(12, weight: .medium))
                                .foregroundStyle(codeCopied ? Theme.green : Theme.blue)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
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

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat = 220,
                       submit: @escaping () -> Void) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.bj(13))
            .padding(10)
            .background(FieldBackground())
            .frame(maxWidth: width)
            .onSubmit(submit)
    }

    // The button's title, with the spinner the Dictionary page uses while its action runs.
    private func label(_ title: String, for action: Action) -> some View {
        HStack(spacing: 6) {
            if busy == action {
                ProgressView().controlSize(.small)
            }
            Text(title)
        }
    }

    // MARK: - Actions

    private func createTeam() {
        let name = teamName.trimmingCharacters(in: .whitespaces)
        guard busy == nil, !name.isEmpty else { return }
        run(.create) {
            try await cloud.createOrg(named: name)
            teamName = ""
            await loadMembers()
        }
    }

    private func joinTeam() {
        let code = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard busy == nil, !code.isEmpty else { return }
        run(.join) {
            try await cloud.joinOrg(code: code)
            joinCode = ""
            await loadMembers()
        }
    }

    private func invite() {
        let address = inviteEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard busy == nil, !address.isEmpty else { return }
        run(.invite) {
            inviteCode = try await cloud.createInvite(email: address)
            inviteFor = address
            inviteEmail = ""
        }
    }

    private func loadMembers() async {
        memberNames = (try? await cloud.members().map(\.displayName)) ?? []
    }

    // One shape for every async action: clear the note, show the error if there is one.
    private func run(_ action: Action, _ work: @escaping () async throws -> Void) {
        busy = action
        note = nil
        Task { @MainActor in
            do { try await work() } catch { note = error.localizedDescription }
            busy = nil
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

// The initial of an address or a team name, in a soft circle.
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

// The hairline between rows of one card.
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

// Signing in, in one place: Settings shows it inside the Account group, the Team page as the whole
// page, and two copies of this drifted apart the moment either was touched. It says "sign in or
// create an account" because that is literally one call — `requestCode` passes `create_user: true`,
// so there is no sign-up form to build.
struct SignInView: View {
    var themeID = Appearance.current
    @ObservedObject var cloud: CloudClient
    // Team fills the page, Settings sits in a card — the difference is only the copy above.
    var showsBlurb = true

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    // Only the email button spins: the Google button stays as Google draws it.
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsBlurb {
                Text("Sign in to back up stats and join a team.")
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
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if sending {
                            ProgressView().controlSize(.small)
                        }
                        Text(codeSent ? "Sign in" : "Email me a code")
                    }
                }
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
                    LogoView(name: "Google_G", size: 14)
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
        sending = true
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

    // Closing the Google sheet is a decision, not a failure, so it leaves no red line behind.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        note = nil
        Task { @MainActor in
            do { try await work() }
            catch is CancellationError {}
            catch { note = error.localizedDescription }
            busy = false
            sending = false
        }
    }

}
