import Foundation

// The Supabase project every cloud feature talks to, named in exactly one place. The project is
// compiled in and has to be: both values used to live only in the per-user defaults domain, so
// accounts worked for whoever had run `defaults write` and were silently off for everyone else. The
// anon key belongs in the binary by design — it is publishable, and db/policies.sql gives the anon
// role nothing at all.
//
// The defaults keys still win when set, which is how a build is pointed at another project:
//
//     defaults write ai.getbluejay.bisprblow cloudURL https://<project>.supabase.co
//     defaults write ai.getbluejay.bisprblow cloudAnonKey <anon key>
//
// An unparseable `cloudURL` turns accounts off entirely: signed out, local-only, no network.
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

    // The scheme Supabase redirects back to after Google. Declared in Info.plist as a
    // CFBundleURLTypes entry, and registered in the project's allowed redirect URLs, or the
    // redirect is refused.
    static let callbackScheme = "bisprblow"
    static var callbackURL: String { "\(callbackScheme)://auth-callback" }
}

// Who is signed in, kept in the Keychain — never in UserDefaults, which anything running as the
// user can read back as a plist.
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

    // Supabase's own messages ("invite code is not valid") are already the right words to show;
    // everything else collapses to one generic line. The log line sits above the parse, because a
    // body that DOES carry a message is the case that reaches the user — "Bad Gateway" arrived
    // parseable and logged nothing. `endpoint` is the URL path only: a query string carries the
    // email address.
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
