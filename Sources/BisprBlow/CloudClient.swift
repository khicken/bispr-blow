import AuthenticationServices
import Foundation
import Security

/// The Supabase project every cloud feature talks to, named in exactly one place.
///
/// The project is compiled in, and it has to be: both values used to live only in the defaults
/// domain, which is per-user — so accounts worked on the machine where someone had run `defaults
/// write` and were silently switched off for everyone who installed the .pkg. `ready` was true
/// for the author and false for every user, which is the worst shape a feature flag can have.
/// The anon key belongs in the binary by design: it is publishable, and db/policies.sql gives the
/// anon role nothing at all.
///
/// The defaults keys still win when set, which is how you point a build at another project:
///
///     defaults write ai.getbluejay.bisprblow cloudURL https://<project>.supabase.co
///     defaults write ai.getbluejay.bisprblow cloudAnonKey <anon key>
///
/// Setting `cloudURL` to something unparseable is the way to turn accounts off entirely: the app
/// is then exactly what it was before they existed — signed out, local-only, no network.
enum CloudConfig {
    static let defaultURL = "https://qprsavobltijpuhwqrhw.supabase.co"
    static let defaultAnonKey = "sb_publishable_5gxuMbpd5SWLKPjw4voD4A_Xjzu3ygi"

    static var url: URL? {
        let stored = AppSettings.shared.cloudURL.trimmingCharacters(in: .whitespaces)
        let raw = stored.isEmpty ? defaultURL : stored
        guard let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static var anonKey: String {
        let stored = AppSettings.shared.cloudAnonKey.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? defaultAnonKey : stored
    }

    static var ready: Bool { url != nil && !anonKey.isEmpty }

    /// The scheme Supabase redirects back to after Google. Declared in Info.plist as a
    /// CFBundleURLTypes entry, and registered in the project's allowed redirect URLs — the
    /// redirect is refused by Supabase if it is not on that list.
    static let callbackScheme = "bisprblow"
    static var callbackURL: String { "\(callbackScheme)://auth-callback" }
}

/// Who is signed in, kept in the Keychain — never in UserDefaults, which anything running as the
/// user can read back as a plist.
struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
    var email: String
}

struct CloudOrg: Equatable {
    let id: UUID
    let name: String
    let role: String
    var isOwner: Bool { role == "owner" }
}

struct OrgMember: Decodable, Identifiable {
    let userID: UUID
    let displayName: String
    let role: String
    var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", displayName = "display_name", role
    }
}

struct LeaderboardRow: Decodable, Identifiable {
    let userID: UUID
    let displayName: String
    let words: Int
    let wpm: Double?
    let dayStreak: Int
    var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", displayName = "display_name", words, wpm
        case dayStreak = "day_streak"
    }
}

struct CloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Supabase's own messages ("invite code is not valid") are already the right words to show;
    /// everything else collapses to one generic line, because status codes and endpoint names are
    /// not information a user acts on.
    /// The log line is above the parse, not in the fallthrough: a body that *does* carry a message
    /// is the case that reaches the user, so it is the case worth having a trace of. "Bad Gateway"
    /// arrived from Supabase's gateway as a parseable message and logged nothing at all. `endpoint`
    /// is the URL path only — a query string carries the email address.
    static func from(_ data: Data, status: Int, endpoint: String) -> CloudError {
        logLine("cloud request failed endpoint=\(endpoint) status=\(status) "
            + "body=\(String(data: data, encoding: .utf8) ?? "")")
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "msg", "error_description"] {
                if let text = object[key] as? String, !text.isEmpty {
                    return CloudError(message: text)
                }
            }
        }
        return CloudError(message: "That didn't work. Try again in a moment.")
    }
}

/// Auth and PostgREST over URLSession — no SDK, no new dependency. All state lives here:
/// `session` (persisted to the Keychain) and `org` (fetched, one org per person; the first
/// joined wins if there are somehow several).
@MainActor
final class CloudClient: ObservableObject {
    static let shared = CloudClient()

    @Published private(set) var session: CloudSession?
    @Published private(set) var org: CloudOrg?

    private init() {
        session = Keychain.load().flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) }
    }

    // MARK: - Auth

    /// Whether the project has a Google client configured. The sign-in view hides its Google button
    /// until this is true, so the button can never be one that cannot succeed. Failing quietly to
    /// `false` is the right default: a hidden button is a smaller wrong than a broken one.
    @Published private(set) var googleEnabled = false

    func refreshProviders() async {
        guard let base = CloudConfig.url else { return }
        var request = URLRequest(url: base.appendingPathComponent("auth/v1/settings"))
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let external = json["external"] as? [String: Any]
        else { return }
        googleEnabled = external["google"] as? Bool ?? false
    }

    /// Step one of signing in: an email with a one-time code.
    ///
    /// `redirect_to` is here for the *link* half of that email, which we do not ask for and cannot
    /// stop: GoTrue's Magic Link template renders `{{ .ConfirmationURL }}` unless the project's
    /// template is changed, and that URL resolves against Site URL — `http://localhost:3000` on an
    /// untouched project. So the mail arrived pointing at a web server that does not exist, which
    /// is exactly what Kaleb reported. GoTrue reads this off the query string rather than the body
    /// (`utilities.GetReferrer`), which is why `auth` takes query items at all. With it the link
    /// lands on `bisprblow://auth-callback` and `AppDelegate` finishes the sign-in — so both halves
    /// of the email now work, whichever the template happens to render.
    func requestCode(email: String) async throws {
        _ = try await auth("otp", json: ["email": email, "create_user": true],
                           query: [.init(name: "redirect_to", value: CloudConfig.callbackURL)])
    }

    /// Step two: the code comes back and becomes a session.
    func signIn(email: String, code: String) async throws {
        let data = try await auth("verify", json: ["type": "email", "email": email, "token": code])
        try adopt(tokenData: data, fallbackEmail: email)
        await refreshOrg()
    }

    /// Google, in a system browser sheet. Supabase answers `authorize` with a redirect to Google
    /// and, once that is done, to `bisprblow://auth-callback` carrying the tokens in the URL
    /// fragment — so nothing here posts credentials, and the app never sees the password.
    ///
    /// Requires a Google client configured in the project's Google provider and this callback in
    /// its redirect allow-list. Until that exists Supabase answers with an error, which arrives
    /// as `CloudError` in its own words and leaves the emailed-code path untouched.
    func signInWithGoogle() async throws {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var components = URLComponents(
            url: base.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: CloudConfig.callbackURL),
        ]
        // Asked before the sheet opens, because a provider that is not configured answers this URL
        // with a JSON error *page* rather than a redirect — so without this the user gets a browser
        // window full of `{"code":400,...}` and closing it looks like they changed their mind.
        // Measured against the live project while Google was still unconfigured:
        // "Unsupported provider: provider is not enabled".
        try await checkProviderEnabled(components.url!)
        try await signIn(callback: try await WebAuth.run(url: components.url!,
                                                         scheme: CloudConfig.callbackScheme))
    }

    /// A `bisprblow://auth-callback` URL becomes a session. Two things arrive here: the tail of the
    /// Google sheet, and the app being opened by the link in a sign-in email (see `requestCode`).
    /// One path for both, so a link that works in the browser cannot stop working in the mail.
    func signIn(callback: URL) async throws {
        let tokens = try Self.tokens(fromCallback: callback)
        let who = try await user(accessToken: tokens.accessToken)
        adopt(accessToken: tokens.accessToken,
              refreshToken: tokens.refreshToken,
              expiresIn: tokens.expiresIn,
              userID: who.id,
              email: who.email)
        await refreshOrg()
    }

    /// Whether `authorize` will redirect rather than refuse. A success here is Google's own consent
    /// page, which is exactly what the sheet is about to load anyway.
    private func checkProviderEnabled(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        guard (200..<400).contains(http.statusCode) else {
            throw CloudError.from(data, status: http.statusCode, endpoint: url.path)
        }
    }

    /// The redirect's fragment, which is where Supabase puts the tokens — `#access_token=...&
    /// refresh_token=...&expires_in=3600`. An `error_description` arrives the same way and is the
    /// server's own wording, so it is shown rather than replaced.
    ///
    /// Pure and `nonisolated` so SelfCheck can exercise it; it is a parser, and it is the only part
    /// of the Google path testable without a configured Google client.
    nonisolated static func tokens(fromCallback url: URL) throws
        -> (accessToken: String, refreshToken: String, expiresIn: Double) {
        let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            values[String(halves[0])] = String(halves[1])
                .replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        if let message = values["error_description"] ?? values["error"] {
            throw CloudError(message: message)
        }
        guard let access = values["access_token"], !access.isEmpty,
              let refresh = values["refresh_token"], !refresh.isEmpty
        else { throw CloudError(message: "Google didn't send a session back. Try again.") }
        return (access, refresh, Double(values["expires_in"] ?? "") ?? 3600)
    }

    func signOut() async {
        if let session, let base = CloudConfig.url {
            var request = URLRequest(url: base.appendingPathComponent("auth/v1/logout"))
            request.httpMethod = "POST"
            request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        session = nil
        org = nil
        Keychain.delete()
        SyncEngine.shared.reset()
    }

    // MARK: - Orgs

    func createOrg(named name: String) async throws {
        _ = try await rest("POST", "rest/v1/rpc/create_org", json: ["name": name])
        await refreshOrg()
        SyncEngine.shared.noteOrgChanged()
    }

    func joinOrg(code: String) async throws {
        _ = try await rest("POST", "rest/v1/rpc/accept_invite", json: ["invite_code": code])
        await refreshOrg()
        SyncEngine.shared.noteOrgChanged()
    }

    /// Issues a code for one teammate's email — the code alone is inert without it (policies.sql).
    /// Handing the code over is the inviter's job (paste it in Slack); nothing is emailed.
    func createInvite(email: String) async throws -> String {
        guard let org, let session else { throw CloudError(message: "Join a team first.") }
        let code = Self.newInviteCode()
        _ = try await rest("POST", "rest/v1/invites", json: [[
            "org_id": org.id.uuidString,
            "email": email,
            "code": code,
            "invited_by": session.userID.uuidString,
            "expires_at": Self.iso.string(from: Date().addingTimeInterval(14 * 24 * 3600)),
        ]], prefer: "return=minimal")
        return code
    }

    func members() async throws -> [OrgMember] {
        guard let org else { return [] }
        let data = try await rest("GET", "rest/v1/org_members", query: [
            .init(name: "org_id", value: "eq.\(org.id.uuidString)"),
            .init(name: "select", value: "user_id,display_name,role"),
            .init(name: "order", value: "joined_at.asc"),
        ])
        return try JSONDecoder().decode([OrgMember].self, from: data)
    }

    /// Which org this account belongs to, if any. Safe to call repeatedly; failures leave `org`
    /// as it was and are logged rather than shown — every caller has a working signed-out state.
    func refreshOrg() async {
        guard let session else { return }
        do {
            let data = try await rest("GET", "rest/v1/org_members", query: [
                .init(name: "user_id", value: "eq.\(session.userID.uuidString)"),
                .init(name: "select", value: "role,orgs(id,name)"),
                .init(name: "order", value: "joined_at.asc"),
                .init(name: "limit", value: "1"),
            ])
            struct Row: Decodable {
                let role: String
                let orgs: Ref
                struct Ref: Decodable {
                    let id: UUID
                    let name: String
                }
            }
            let rows = try JSONDecoder().decode([Row].self, from: data)
            org = rows.first.map { CloudOrg(id: $0.orgs.id, name: $0.orgs.name, role: $0.role) }
        } catch {
            logLine("cloud org fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Data

    func leaderboard(period: String) async throws -> [LeaderboardRow] {
        guard let org else { return [] }
        let data = try await rest("GET", "rest/v1/leaderboard", query: [
            .init(name: "org_id", value: "eq.\(org.id.uuidString)"),
            .init(name: "period", value: "eq.\(period)"),
            .init(name: "select", value: "user_id,display_name,words,wpm,day_streak"),
            .init(name: "order", value: "words.desc"),
        ])
        return try JSONDecoder().decode([LeaderboardRow].self, from: data)
    }

    /// Batch upsert keyed on the client-minted entry UUID, so retries are free and a push can
    /// never duplicate a dictation.
    func upsertDictations(_ rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await rest("POST", "rest/v1/dictations", json: rows,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    func upsertTexts(_ rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await rest("POST", "rest/v1/dictation_texts", json: rows,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    // MARK: - Plumbing

    /// Who the stored session belongs to, read straight from the Keychain. `nonisolated` so
    /// `--cloud-check` can ask without hopping to the MainActor: `awaitSync` blocks the main thread,
    /// so a hop there from a CLI path deadlocks outright and reads as a hang, not an error.
    nonisolated static func storedSessionEmail() -> String? {
        Keychain.load()
            .flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) }
            .map(\.email)
    }

    /// 8 characters from an alphabet with no 0/O, 1/I/L — a code someone reads out loud.
    nonisolated static func newInviteCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    /// `unsafe` in name only: ISO8601DateFormatter is documented thread-safe.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func auth(_ endpoint: String, json: [String: Any],
                      query: [URLQueryItem] = []) async throws -> Data {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var components = URLComponents(url: base.appendingPathComponent("auth/v1/\(endpoint)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private func rest(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      json: Any? = nil, prefer: String? = nil) async throws -> Data {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError(message: "No answer from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.from(data, status: http.statusCode,
                                  endpoint: request.url?.path ?? "?")
        }
        return data
    }

    /// A valid bearer token, refreshed just before it expires. A refresh the server rejects means
    /// the session is gone (revoked, or long dead), so the app returns to signed out rather than
    /// wedging every request behind a token that can never work.
    private func accessToken() async throws -> String {
        guard let current = session else { throw CloudError(message: "Sign in first.") }
        if current.expiresAt > Date().addingTimeInterval(60) { return current.accessToken }
        do {
            let data = try await auth("token?grant_type=refresh_token",
                                      json: ["refresh_token": current.refreshToken])
            try adopt(tokenData: data, fallbackEmail: current.email)
        } catch {
            session = nil
            org = nil
            Keychain.delete()
            throw CloudError(message: "You've been signed out. Sign in again from Settings.")
        }
        return session!.accessToken
    }

    private func adopt(tokenData: Data, fallbackEmail: String) throws {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double
            let user: User
            struct User: Decodable {
                let id: UUID
                let email: String?
            }
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token", refreshToken = "refresh_token"
                case expiresIn = "expires_in", user
            }
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
        adopt(accessToken: token.accessToken,
              refreshToken: token.refreshToken,
              expiresIn: token.expiresIn,
              userID: token.user.id,
              email: token.user.email ?? fallbackEmail)
    }

    /// The one place a session is built and stored. The OAuth redirect hands back three token
    /// values in a URL fragment and no user object at all, so the identity arrives separately —
    /// which is why this takes the pieces rather than a response body.
    private func adopt(accessToken: String, refreshToken: String, expiresIn: Double,
                       userID: UUID, email: String) {
        let fresh = CloudSession(accessToken: accessToken,
                                 refreshToken: refreshToken,
                                 expiresAt: Date().addingTimeInterval(expiresIn),
                                 userID: userID,
                                 email: email)
        session = fresh
        if let data = try? JSONEncoder().encode(fresh) { Keychain.save(data) }
    }

    /// Who a bare access token belongs to. Asked of the server rather than decoded out of the JWT:
    /// the payload does carry `sub` and `email`, but reading identity out of a token this app has
    /// not verified is trusting a string, and this is one request through the same path as the rest.
    private func user(accessToken: String) async throws -> (id: UUID, email: String) {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var request = URLRequest(url: base.appendingPathComponent("auth/v1/user"))
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        struct User: Decodable {
            let id: UUID
            let email: String?
        }
        let decoded = try JSONDecoder().decode(User.self, from: try await send(request))
        return (decoded.id, decoded.email ?? "")
    }
}

/// One generic-password item holding the session JSON.
private enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ai.getbluejay.bisprblow",
         kSecAttrAccount as String: "cloud-session"]
    }

    static func save(_ data: Data) {
        delete()
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> Data? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// `ASWebAuthenticationSession` as one `await`. The session has to outlive the call that starts it
/// or the sheet closes immediately, and its delegate is a separate object, so both are held here
/// until the callback lands.
///
/// `prefersEphemeralWebBrowserSession` is false on purpose: a signed-in Google in Safari is the
/// difference between a click and typing a password, and the point of this button is that it is
/// faster than the emailed code.
@MainActor
private final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var live: WebAuth?

    static func run(url: URL, scheme: String) async throws -> URL {
        let auth = WebAuth()
        live = auth
        defer { live = nil }
        return try await auth.start(url: url, scheme: scheme)
    }

    private func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: scheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: CloudError(
                        message: error?.localizedDescription ?? "Google sign-in didn't finish."))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: CloudError(
                    message: "Couldn't open a browser for Google sign-in."))
                return
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The dashboard window when it is open. An accessory app can have no window at all, and
        // `ASPresentationAnchor()` is the documented "no particular window" anchor.
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
