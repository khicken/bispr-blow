using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace BisprBlow;

// The Supabase project every cloud feature talks to, named in exactly one place. The project is
// compiled in and has to be: both values used to live only in the per-user settings, so accounts
// worked for whoever had edited them and were silently off for everyone else. The anon key belongs in
// the binary by design — it is publishable, and db/policies.sql gives the anon role nothing at all.
//
// The settings file's cloudURL and cloudAnonKey still win when set, which is how a build is pointed at
// another project. An unparseable cloudURL turns accounts off entirely: signed out, local-only, no network.
public static class CloudConfig
{
    public const string DefaultURL = "https://qprsavobltijpuhwqrhw.supabase.co";
    public const string DefaultAnonKey = "sb_publishable_5gxuMbpd5SWLKPjw4voD4A_Xjzu3ygi";

    public static Uri? Url
    {
        get
        {
            var stored = AppSettings.Shared.CloudURL.Trim();
            return Uri.TryCreate(stored.Length == 0 ? DefaultURL : stored, UriKind.Absolute, out var url)
                   && url.Scheme == Uri.UriSchemeHttps ? url : null;
        }
    }

    public static string AnonKey
    {
        get
        {
            var stored = AppSettings.Shared.CloudAnonKey.Trim();
            return stored.Length == 0 ? DefaultAnonKey : stored;
        }
    }

    public static bool Ready => Url != null && AnonKey.Length > 0;

    // The scheme Supabase redirects back to after Google. Registered under HKCU by
    // CloudClient.RegisterUrlScheme, and in the project's allowed redirect URLs, or the redirect is refused.
    public const string CallbackScheme = "bisprblow";
    public static string CallbackURL => $"{CallbackScheme}://auth-callback";
}

// Who is signed in, kept DPAPI-encrypted — never in settings.json, which anything running as the user
// can read.
public sealed record CloudSession(string AccessToken, string RefreshToken, DateTime ExpiresAt, Guid UserID, string Email);

public sealed record CloudOrg(Guid Id, string Name, string Role)
{
    public bool IsOwner => Role == "owner";
}

// One row of the team roster. `users` is an embedded single object (PostgREST follows the foreign
// key), and null when the viewer cannot read that user, so email is optional.
public sealed record OrgMember(Guid UserID, string Role, string? Email, string MemberName, string? AccountName)
{
    public Guid Id => UserID;
    public bool IsOwner => Role == "owner";

    // The name the member chose for this team, then the one on their account, then the start of
    // their address, so a row is never blank.
    public string DisplayName
    {
        get
        {
            foreach (var candidate in new[] { MemberName, AccountName ?? "" })
                if (candidate.Trim() is { Length: > 0 } trimmed) return trimmed;
            return Email?.Split('@')[0] is { Length: > 0 } local ? local : "Teammate";
        }
    }

    public static List<OrgMember> ParseList(string json) =>
        JsonNode.Parse(json)!.AsArray().Select(row => new OrgMember(
            (Guid)row!["user_id"]!, (string)row["role"]!,
            (string?)row["users"]?["email"], (string?)row["display_name"] ?? "",
            (string?)row["users"]?["display_name"])).ToList();
}

// The pure halves of dictionary sharing, kept free of the network so the self-check can run them.
public static class DictionaryWords
{
    // `dictionary_words.word` is capped at 200 characters server-side. NUL is refused by Postgres.
    public const int MaxLength = 200;

    // Trimmed, no empties, capped, and unique ignoring case — the first spelling wins.
    public static List<string> Clean(IEnumerable<string> words)
    {
        var seen = new HashSet<string>();
        return words.Select(w =>
            {
                var text = w.Replace("\0", "").Trim();
                if (text.Length <= MaxLength) return text;
                // Never cut a surrogate pair in half.
                return text[..(char.IsHighSurrogate(text[MaxLength - 1]) ? MaxLength - 1 : MaxLength)];
            })
            .Where(w => w.Length > 0 && seen.Add(w.ToLowerInvariant())).ToList();
    }

    // What to send to bring the server in line with this PC. `synced` is what this PC last
    // sent, so a word another device uploaded is never deleted from here. Exact spelling, not case
    // folded: a recased word is an upsert of the new spelling and a delete of the old one.
    public static (List<string> Upsert, List<string> Delete) Plan(IEnumerable<string> local, ISet<string> synced)
    {
        var have = local.ToHashSet();
        return (local.Where(w => !synced.Contains(w)).ToList(),
                synced.Where(w => !have.Contains(w)).Order(StringComparer.Ordinal).ToList());
    }

    // A teammate's words that are not already in mine, ignoring case.
    public static List<string> Importable(IEnumerable<string> theirs, IEnumerable<string> mine)
    {
        var known = mine.Select(w => w.ToLowerInvariant()).ToHashSet();
        return Clean(theirs).Where(w => !known.Contains(w.ToLowerInvariant())).ToList();
    }

    // A PostgREST `in.(...)` list. Each value is double-quoted, so commas, parentheses and spaces
    // are data; inside the quotes only `\` and `"` need escaping.
    public static string InList(IEnumerable<string> words) =>
        "in.(" + string.Join(",", words.Select(w => "\"" + w.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"")) + ")";
}

public sealed record LeaderboardRow(
    [property: JsonPropertyName("user_id")] Guid UserID,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("words")] int Words,
    [property: JsonPropertyName("wpm")] double? Wpm,
    [property: JsonPropertyName("day_streak")] int DayStreak)
{
    public Guid Id => UserID;
}

public sealed class CloudError(string message, int? status = null) : Exception(message)
{
    public int? Status { get; } = status;

    // Supabase's own messages ("invite code is not valid") are already the right words to show;
    // everything else collapses to one generic line. The log line sits above the parse, because a
    // body that DOES carry a message is the case that reaches the user — "Bad Gateway" arrived
    // parseable and logged nothing. `endpoint` is the URL path only: a query string carries the
    // email address.
    public static CloudError From(string body, int status, string endpoint)
    {
        Log.Line($"cloud request failed endpoint={endpoint} status={status} body={body}");
        try
        {
            if (JsonNode.Parse(body) is JsonObject obj)
                foreach (var key in new[] { "message", "msg", "error_description" })
                    if (obj[key] is JsonValue v && v.TryGetValue<string>(out var text) && text.Length > 0)
                        return new CloudError(text, status);
        }
        catch (JsonException) { }
        return new CloudError("That didn't work. Try again in a moment.", status);
    }
}
