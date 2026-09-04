import AuthenticationServices
import Foundation
import Security

// Auth and PostgREST over URLSession — no SDK, no new dependency. All state lives here: `session`
// (persisted to the Keychain) and `org` (one org per person; the first joined wins).
@MainActor
final class CloudClient: ObservableObject {
    static let shared = CloudClient()

    @Published private(set) var session: CloudSession?
    @Published private(set) var org: CloudOrg?

    private init() {
        session = Keychain.load().flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) }
    }

    // MARK: - Auth

    // Whether the project has a Google client configured. The sign-in view hides its Google button
    // until this is true, so the button can never be one that cannot succeed. Failing quietly to
    // `false` is right: a hidden button is a smaller wrong than a broken one.
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

    // Step one of signing in: an email with a one-time code. `redirect_to` is for the LINK half of
    // that email, which we do not ask for and cannot stop: GoTrue's Magic Link template renders
    // `{{ .ConfirmationURL }}` unless the project's template is changed, and that resolves against
    // Site URL — `http://localhost:3000` on an untouched project. GoTrue reads this off the query
    // string (`utilities.GetReferrer`), which is why `auth` takes query items at all. With it the
    // link lands on `bisprblow://auth-callback` and `AppDelegate` finishes the sign-in.
    func requestCode(email: String) async throws {
        _ = try await auth("otp", json: ["email": email, "create_user": true],
                           query: [.init(name: "redirect_to", value: CloudConfig.callbackURL)])
    }

    // Step two: the code comes back and becomes a session.
    func signIn(email: String, code: String) async throws {
        let data = try await auth("verify", json: ["type": "email", "email": email, "token": code])
        try adopt(tokenData: data, fallbackEmail: email)
        await refreshOrg()
    }

    // Google, in a system browser sheet: Supabase redirects to Google and then to
    // `bisprblow://auth-callback` with the tokens in the URL fragment, so nothing here posts
    // credentials. Requires a Google client configured in the project and this callback in its
    // redirect allow-list; until then Supabase answers with an error in its own words.
    func signInWithGoogle() async throws {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var components = URLComponents(
            url: base.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: CloudConfig.callbackURL),
        ]
        // Asked before the sheet opens, because an unconfigured provider answers this URL with a
        // JSON error PAGE rather than a redirect, so the user would get a browser window full of
        // `{"code":400,...}`. Measured against the live project: "Unsupported provider: provider is
        // not enabled".
        try await checkProviderEnabled(components.url!)
        try await signIn(callback: try await WebAuth.run(url: components.url!,
                                                         scheme: CloudConfig.callbackScheme))
    }

    // A `bisprblow://auth-callback` URL becomes a session. Two things arrive here: the tail of the
    // Google sheet, and the app opened by the link in a sign-in email. One path for both.
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

    // Whether `authorize` will redirect rather than refuse. A success here is Google's own consent
    // page, which the sheet is about to load anyway.
    private func checkProviderEnabled(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        guard (200..<400).contains(http.statusCode) else {
            throw CloudError.from(data, status: http.statusCode, endpoint: url.path)
        }
    }

    // The redirect's fragment, where Supabase puts the tokens — `#access_token=...&refresh_token=...
    // &expires_in=3600`. An `error_description` arrives the same way and is shown as-is. Pure and
    // `nonisolated` so SelfCheck can exercise it: it is the only part of the Google path testable
    // without a configured Google client.
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

    // Issues a code for one teammate's email — the code alone is inert without it (policies.sql).
    // Handing it over is the inviter's job; nothing is emailed.
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

    // Which org this account belongs to, if any. Safe to call repeatedly; failures leave `org` as it
    // was and are logged rather than shown.
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

    // Batch upsert keyed on the client-minted entry UUID, so retries are free and a push can never
    // duplicate a dictation.
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

    // Who the stored session belongs to, read straight from the Keychain. `nonisolated` so
    // `--cloud-check` can ask without hopping to the MainActor: `awaitSync` blocks the main thread,
    // so a hop from a CLI path deadlocks and reads as a hang.
    nonisolated static func storedSessionEmail() -> String? {
        Keychain.load()
            .flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) }
            .map(\.email)
    }

    // 8 characters from an alphabet with no 0/O, 1/I/L — a code someone reads out loud.
    nonisolated static func newInviteCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // `unsafe` in name only: ISO8601DateFormatter is documented thread-safe.
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

    // A valid bearer token, refreshed just before it expires. A refresh the server rejects means the
    // session is gone, so the app returns to signed out rather than wedging every request.
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

    // The one place a session is built and stored. The OAuth redirect hands back three token values
    // in a URL fragment and no user object, so the identity arrives separately — which is why this
    // takes the pieces rather than a response body.
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

    // Who a bare access token belongs to. Asked of the server rather than decoded out of the JWT:
    // reading identity out of a token this app has not verified is trusting a string.
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

// One generic-password item holding the session JSON.
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

// `ASWebAuthenticationSession` as one `await`. The session has to outlive the call that starts it
// or the sheet closes immediately, and its delegate is a separate object, so both are held here
// until the callback lands. `prefersEphemeralWebBrowserSession` is false on purpose: a signed-in
// Google in Safari is the difference between a click and typing a password.
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
