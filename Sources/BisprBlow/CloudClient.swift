import AppKit
import Foundation
import Security

// Auth and PostgREST over URLSession — no SDK, no new dependency. All state lives here: `session`
// (persisted to the Keychain) and `org` (one org per person; the first joined wins).
@MainActor
final class CloudClient: ObservableObject {
    static let shared = CloudClient()

    @Published private(set) var session: CloudSession?
    @Published private(set) var org: CloudOrg?
    @Published private(set) var roster: [OrgMember] = []
    private var refreshTask: Task<String, Error>?

    private init() {
        session = Keychain.load().flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) }
    }

    // MARK: - Auth

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

    // Google, in the user's default browser: Supabase redirects to Google and then to
    // `bisprblow://auth-callback` with the tokens in the URL fragment, so nothing here posts
    // credentials. Requires a Google client configured in the project and this callback in its
    // redirect allow-list; until then Supabase answers with an error in its own words.
    //
    // Not `ASWebAuthenticationSession`, which opens Safari for any default browser that does not
    // adopt its API. The callback returns through `application(_:open:)`, which calls
    // `finishGoogle`. A closed tab sends nothing back, so a second click supersedes the wait.
    func signInWithGoogle() async throws {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var components = URLComponents(
            url: base.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: CloudConfig.callbackURL),
        ]
        // Asked before the browser opens, because an unconfigured provider answers this URL with a
        // JSON error PAGE rather than a redirect, so the user would get a browser window full of
        // `{"code":400,...}`. Measured against the live project: "Unsupported provider: provider is
        // not enabled".
        let url = components.url!
        try await checkProviderEnabled(url)
        if let superseded = googleCallback {
            googleCallback = nil
            superseded.resume(throwing: CancellationError())
        }
        let callback = try await withCheckedThrowingContinuation { continuation in
            googleCallback = continuation
            guard NSWorkspace.shared.open(url) else {
                googleCallback = nil
                continuation.resume(throwing: CloudError(
                    message: "Couldn't open a browser for Google sign-in."))
                return
            }
        }
        try await signIn(callback: callback)
    }

    private var googleCallback: CheckedContinuation<URL, Error>?

    // True when a Google sign-in was waiting for this callback. False means it is an email link.
    func finishGoogle(_ callback: URL) -> Bool {
        guard let waiting = googleCallback else { return false }
        googleCallback = nil
        waiting.resume(returning: callback)
        return true
    }

    // A `bisprblow://auth-callback` URL becomes a session. Two things arrive here: the tail of the
    // Google browser tab, and the app opened by the link in a sign-in email. One path for both.
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
        setOrg(nil)
        Keychain.delete()
        SyncEngine.shared.reset()
    }

    // MARK: - Orgs

    func createOrg(named name: String) async throws {
        _ = try await rest("POST", "rest/v1/rpc/create_org", json: ["name": name])
        try await fetchOrg()
        SyncEngine.shared.noteOrgChanged()
    }

    func joinOrg(code: String) async throws {
        _ = try await rest("POST", "rest/v1/rpc/accept_invite", json: ["invite_code": code])
        try await fetchOrg()
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

    // Owner only; the server enforces it. A non-owner's PATCH matches no rows and still answers
    // 204, so the UI never offers this to anyone else.
    func renameOrg(to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let org else { throw CloudError(message: "Join a team first.") }
        guard !trimmed.isEmpty else { throw CloudError(message: "Give the team a name.") }
        _ = try await rest("PATCH", "rest/v1/orgs",
                           query: [.init(name: "id", value: "eq.\(org.id.uuidString)")],
                           json: ["name": trimmed], prefer: "return=minimal")
        if self.org?.id == org.id {
            self.org = CloudOrg(id: org.id, name: trimmed, role: org.role)
        }
    }

    // The roster, which also feeds the recognizer: teammates' names are the words most worth
    // spelling right. Kept on the client so it works without the Team page ever being opened.
    func refreshRoster() async throws {
        guard let org else { return }
        let data = try await rest("GET", "rest/v1/org_members", query: [
            .init(name: "org_id", value: "eq.\(org.id.uuidString)"),
            .init(name: "select", value: "user_id,display_name,role,joined_at,users(email,display_name)"),
            .init(name: "order", value: "joined_at.asc"),
        ])
        let rows = try JSONDecoder().decode([OrgMember].self, from: data)
        guard self.org?.id == org.id else { return }
        roster = rows
        AppSettings.shared.rosterNames = rows.map(\.displayName)
    }

    func dictionaryWords(of userID: UUID) async throws -> [String] {
        let data = try await rest("GET", "rest/v1/dictionary_words", query: [
            .init(name: "user_id", value: "eq.\(userID.uuidString)"),
            .init(name: "select", value: "word"),
            .init(name: "order", value: "word.asc"),
        ])
        struct Row: Decodable { let word: String }
        return try JSONDecoder().decode([Row].self, from: data).map(\.word)
    }

    func upsertDictionaryWords(_ words: [String]) async throws {
        guard let session, !words.isEmpty else { return }
        _ = try await rest("POST", "rest/v1/dictionary_words",
                           json: words.map { ["user_id": session.userID.uuidString, "word": $0] },
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    func deleteDictionaryWords(_ words: [String]) async throws {
        guard let session, !words.isEmpty else { return }
        _ = try await rest("DELETE", "rest/v1/dictionary_words", query: [
            .init(name: "user_id", value: "eq.\(session.userID.uuidString)"),
            .init(name: "word", value: DictionaryWords.inList(words)),
        ], prefer: "return=minimal")
    }

    // Which org this account belongs to, if any. Safe to call repeatedly; failures leave `org` as it
    // was and are logged rather than shown.
    func refreshOrg() async {
        do {
            try await fetchOrg()
        } catch {
            logLine("cloud org fetch failed: \(error.localizedDescription)")
        }
    }

    // Throwing form for create/join: their RPC has already committed, so a failed fetch must reach
    // the caller or the form stays up with `org` nil and a second tap creates a duplicate.
    private func fetchOrg() async throws {
        guard let session else { return }
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
        setOrg(rows.first.map { CloudOrg(id: $0.orgs.id, name: $0.orgs.name, role: $0.role) })
        if org != nil {
            do { try await refreshRoster() } catch { logLine("cloud roster fetch failed: \(error.localizedDescription)") }
        }
    }

    // The one place `org` changes, so the roster and the names it feeds the recognizer never
    // outlive the team they came from.
    private func setOrg(_ new: CloudOrg?) {
        if new?.id != org?.id {
            roster = []
            AppSettings.shared.rosterNames = []
        }
        org = new
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

    // URLComponents leaves `+` raw in a query value, and PostgREST reads a raw `+` as a space, so
    // a word like "C++" would match the wrong row. Every real plus is a plus, since spaces are
    // already %20 by this point.
    nonisolated static func url(_ base: URL, _ path: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func rest(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      json: Any? = nil, prefer: String? = nil) async throws -> Data {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var request = URLRequest(url: Self.url(base, path, query))
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
    // session is gone, so the app returns to signed out rather than wedging every request. Being
    // offline, rate limited or a 5xx keeps the session for the next try.
    private func accessToken() async throws -> String {
        guard let current = session else { throw CloudError(message: "Sign in first.") }
        if current.expiresAt > Date().addingTimeInterval(60) { return current.accessToken }
        return try await refreshSession(current)
    }

    // One refresh shared by every caller that finds the token expired: GoTrue rotates refresh
    // tokens, so a second concurrent POST would get `refresh_token_already_used` and sign the
    // person out for nothing.
    private func refreshSession(_ current: CloudSession) async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: CloudSession) async throws -> String {
        do {
            let data = try await auth("token", json: ["refresh_token": current.refreshToken],
                                      query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
            do {
                try adopt(tokenData: data, fallbackEmail: current.email)
            } catch is DecodingError {
                throw CloudError(message: "That didn't work. Try again in a moment.")
            }
        } catch let error as CloudError where Self.endsSession(error.status) {
            session = nil
            setOrg(nil)
            Keychain.delete()
            throw CloudError(message: "You've been signed out. Sign in again from Settings.")
        }
        guard let session else { throw CloudError(message: "Sign in first.") }
        return session.accessToken
    }

    // Any 4xx means the server looked at this refresh token and refused it, except the two that
    // say "try again": 408 and 429.
    private static func endsSession(_ status: Int?) -> Bool {
        guard let status else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
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
