import Foundation
import Security

/// The Supabase project every cloud feature talks to, named in exactly one place. Both values are
/// empty until configured:
///
///     defaults write ai.getbluejay.wispr cloudURL https://<project>.supabase.co
///     defaults write ai.getbluejay.wispr cloudAnonKey <anon key>
///
/// then relaunch. While either is empty the app is exactly what it was before accounts existed:
/// signed out, local-only, no Account section and no network. The anon key is publishable by
/// design — db/policies.sql gives the anon role nothing at all.
enum CloudConfig {
    static var url: URL? {
        let raw = AppSettings.shared.cloudURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static var anonKey: String {
        AppSettings.shared.cloudAnonKey.trimmingCharacters(in: .whitespaces)
    }

    static var ready: Bool { url != nil && !anonKey.isEmpty }
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
    static func from(_ data: Data, status: Int) -> CloudError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "msg", "error_description"] {
                if let text = object[key] as? String, !text.isEmpty {
                    return CloudError(message: text)
                }
            }
        }
        logLine("cloud request failed status=\(status) body=\(String(data: data, encoding: .utf8) ?? "")")
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

    /// Step one of signing in: an email with a one-time code.
    func requestCode(email: String) async throws {
        _ = try await auth("otp", json: ["email": email, "create_user": true])
    }

    /// Step two: the code comes back and becomes a session.
    func signIn(email: String, code: String) async throws {
        let data = try await auth("verify", json: ["type": "email", "email": email, "token": code])
        try adopt(tokenData: data, fallbackEmail: email)
        await refreshOrg()
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

    private func auth(_ endpoint: String, json: [String: Any]) async throws -> Data {
        guard let base = CloudConfig.url else { throw CloudError(message: "Accounts aren't set up.") }
        var request = URLRequest(url: base.appendingPathComponent("auth/v1/\(endpoint)"))
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
            throw CloudError.from(data, status: http.statusCode)
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
        let fresh = CloudSession(accessToken: token.accessToken,
                                 refreshToken: token.refreshToken,
                                 expiresAt: Date().addingTimeInterval(token.expiresIn),
                                 userID: token.user.id,
                                 email: token.user.email ?? fallbackEmail)
        session = fresh
        if let data = try? JSONEncoder().encode(fresh) { Keychain.save(data) }
    }
}

/// One generic-password item holding the session JSON.
private enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ai.getbluejay.wispr",
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
