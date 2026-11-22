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

// One row of the team roster. `users` is an embedded single object (PostgREST follows the foreign
// key), and null when the viewer cannot read that user, so email is optional.
struct OrgMember: Decodable, Identifiable, Equatable {
    let userID: UUID
    let role: String
    let email: String?
    private let memberName: String
    private let accountName: String?
    var id: UUID { userID }
    var isOwner: Bool { role == "owner" }

    // The name the member chose for this team, then the one on their account, then the start of
    // their address, so a row is never blank.
    var displayName: String {
        for candidate in [memberName, accountName ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return email?.split(separator: "@").first.map(String.init) ?? "Teammate"
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", memberName = "display_name", role, users
    }

    private struct Account: Decodable {
        let email: String?
        let displayName: String?
        enum CodingKeys: String, CodingKey { case email, displayName = "display_name" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(UUID.self, forKey: .userID)
        role = try container.decode(String.self, forKey: .role)
        memberName = try container.decodeIfPresent(String.self, forKey: .memberName) ?? ""
        let account = try container.decodeIfPresent(Account.self, forKey: .users)
        email = account?.email
        accountName = account?.displayName
    }
}

// The pure halves of dictionary sharing, kept free of the network so the self-check can run them.
enum DictionaryWords {
    // `dictionary_words.word` is capped at 200 characters server-side. NUL is refused by Postgres.
    static let maxLength = 200

    // Trimmed, no empties, capped, and unique ignoring case — the first spelling wins.
    static func clean(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words
            .map { String($0.replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // What to send to bring the server in line with this Mac. `synced` is what this Mac last
    // sent, so a word another device uploaded is never deleted from here. Exact spelling, not case
    // folded: a recased word is an upsert of the new spelling and a delete of the old one.
    static func plan(local: [String], synced: Set<String>) -> (upsert: [String], delete: [String]) {
        let have = Set(local)
        return (local.filter { !synced.contains($0) }, synced.filter { !have.contains($0) }.sorted())
    }

    // A teammate's words that are not already in mine, ignoring case.
    static func importable(theirs: [String], mine: [String]) -> [String] {
        let known = Set(mine.map { $0.lowercased() })
        return clean(theirs).filter { !known.contains($0.lowercased()) }
    }

    // A PostgREST `in.(...)` list. Each value is double-quoted, so commas, parentheses and spaces
    // are data; inside the quotes only `\` and `"` need escaping.
    static func inList(_ words: [String]) -> String {
        let quoted = words.map { word in
            "\"" + word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "in.(" + quoted.joined(separator: ",") + ")"
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
    var status: Int?
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
                    return CloudError(message: text, status: status)
                }
            }
        }
        return CloudError(message: "That didn't work. Try again in a moment.", status: status)
    }
}
