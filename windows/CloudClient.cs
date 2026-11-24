using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace BisprBlow;

// Auth and PostgREST over HttpClient — no SDK, no new dependency. All state lives here: `Session`
// (persisted DPAPI-encrypted) and `Org` (one org per person; the first joined wins). Views subscribe
// to PropertyChanged and marshal to their own dispatcher; continuations here run on the caller's.
public sealed class CloudClient : INotifyPropertyChanged
{
    public static readonly CloudClient Shared = new();

    // One for the whole app: HttpClient is meant to be shared, and UpdateChecker uses it too.
    internal static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };

    static readonly JsonSerializerOptions Json = new() { NumberHandling = JsonNumberHandling.AllowReadingFromString };

    public event PropertyChangedEventHandler? PropertyChanged;

    void Set<T>(ref T field, T value, [CallerMemberName] string name = "")
    {
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // Why the last email-link sign-in failed. Shown above the sign-in form.
    string? authNote;
    public string? AuthNote { get => authNote; set => Set(ref authNote, value); }

    CloudSession? session;
    public CloudSession? Session { get => session; private set => Set(ref session, value); }

    CloudOrg? org;
    public CloudOrg? Org { get => org; private set => Set(ref org, value); }

    IReadOnlyList<OrgMember> roster = [];
    public IReadOnlyList<OrgMember> Roster { get => roster; private set => Set(ref roster, value); }

    Task<string>? refreshTask;

    CloudClient()
    {
        session = SessionStore.Load();
    }

    // MARK: - Auth

    // Step one of signing in: an email with a one-time code. `redirect_to` is for the LINK half of
    // that email, which we do not ask for and cannot stop: GoTrue's Magic Link template renders
    // `{{ .ConfirmationURL }}` unless the project's template is changed, and that resolves against
    // Site URL — `http://localhost:3000` on an untouched project. GoTrue reads this off the query
    // string (`utilities.GetReferrer`), which is why `Auth` takes query items at all. With it the
    // link lands on `bisprblow://auth-callback` and HandleCallbackAsync finishes the sign-in.
    public async Task RequestCodeAsync(string email) =>
        await Auth("otp", new { email, create_user = true }, [("redirect_to", CloudConfig.CallbackURL)]);

    // Step two: the code comes back and becomes a session.
    public async Task SignInAsync(string email, string code)
    {
        var data = await Auth("verify", new { type = "email", email, token = code });
        Adopt(data, email);
        await RefreshOrgAsync();
    }

    // Google, in the user's default browser: Supabase redirects to Google and then to
    // `bisprblow://auth-callback` with the tokens in the URL fragment, so nothing here posts
    // credentials. Requires a Google client configured in the project and this callback in its
    // redirect allow-list; until then Supabase answers with an error in its own words.
    //
    // The callback comes back through the registered URL scheme: Windows starts a second copy with the
    // URL, which hands it to the running one, and that calls HandleCallbackAsync. A closed tab sends
    // nothing back, so a second click supersedes the wait.
    public async Task SignInWithGoogleAsync()
    {
        if (CloudConfig.Url is not { } baseUrl) throw new CloudError("Accounts aren't set up.");
        var url = Url(baseUrl, "auth/v1/authorize",
                      [("provider", "google"), ("redirect_to", CloudConfig.CallbackURL)]);
        // Asked before the browser opens, because an unconfigured provider answers this URL with a
        // JSON error PAGE rather than a redirect, so the user would get a browser window full of
        // `{"code":400,...}`. Measured against the live project: "Unsupported provider: provider is
        // not enabled".
        await CheckProviderEnabled(url);
        googleCallback?.TrySetCanceled();
        var waiting = googleCallback = new TaskCompletionSource<Uri>(TaskCreationOptions.RunContinuationsAsynchronously);
        try { Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            googleCallback = null;
            throw new CloudError("Couldn't open a browser for Google sign-in.");
        }
        await SignInAsync(await waiting.Task);
    }

    TaskCompletionSource<Uri>? googleCallback;

    // Ends a Google wait the user gave up on; the awaiting sign-in throws a cancellation.
    public void CancelGoogle()
    {
        googleCallback?.TrySetCanceled();
        googleCallback = null;
    }

    // True when a Google sign-in was waiting for this callback. False means it is an email link.
    public bool FinishGoogle(Uri callback)
    {
        if (googleCallback is not { } waiting) return false;
        googleCallback = null;
        waiting.TrySetResult(callback);
        return true;
    }

    // What the app does with a `bisprblow://auth-callback` URL, however it arrived. A Google
    // sign-in in flight takes it; otherwise it is the link in a sign-in email, and a failure shows
    // the Team page anyway, since an expired link has to say so somewhere.
    public async Task HandleCallbackAsync(Uri callback)
    {
        if (callback.Scheme != CloudConfig.CallbackScheme || FinishGoogle(callback)) return;
        DashboardWindow.Show(DashboardSection.Team);
        try { await SignInAsync(callback); }
        catch (Exception e)
        {
            Log.Line($"cloud: email link sign-in failed: {e.Message}");
            AuthNote = $"Sign-in failed: {e.Message}";
        }
    }

    // A `bisprblow://auth-callback` URL becomes a session. Two things arrive here: the tail of the
    // Google browser tab, and the app opened by the link in a sign-in email. One path for both.
    public async Task SignInAsync(Uri callback)
    {
        var tokens = Tokens(callback);
        var who = await UserAsync(tokens.AccessToken);
        Adopt(tokens.AccessToken, tokens.RefreshToken, tokens.ExpiresIn, who.Id, who.Email);
        await RefreshOrgAsync();
    }

    // Whether `authorize` will redirect rather than refuse. A success here is Google's own consent
    // page, which the browser is about to load anyway.
    static async Task CheckProviderEnabled(Uri url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("apikey", CloudConfig.AnonKey);
        string body;
        int status;
        try
        {
            using var response = await Http.SendAsync(request);
            status = (int)response.StatusCode;
            body = await response.Content.ReadAsStringAsync();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { return; }
        if (status is < 200 or >= 400) throw CloudError.From(body, status, url.AbsolutePath);
    }

    // The redirect's fragment, where Supabase puts the tokens — `#access_token=...&refresh_token=...
    // &expires_in=3600`. An `error_description` arrives the same way and is shown as-is. Pure so
    // SelfCheck can exercise it: it is the only part of the Google path testable without a
    // configured Google client.
    public static (string AccessToken, string RefreshToken, double ExpiresIn) Tokens(Uri url)
    {
        var values = new Dictionary<string, string>();
        foreach (var pair in url.Fragment.TrimStart('#').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var halves = pair.Split('=', 2);
            if (halves.Length != 2) continue;
            try { values[halves[0]] = Uri.UnescapeDataString(halves[1].Replace('+', ' ')); }
            catch (UriFormatException) { }
        }
        if ((values.GetValueOrDefault("error_description") ?? values.GetValueOrDefault("error")) is { } message)
            throw new CloudError(message);
        if (values.GetValueOrDefault("access_token") is not { Length: > 0 } access
            || values.GetValueOrDefault("refresh_token") is not { Length: > 0 } refresh)
            throw new CloudError("Google didn't send a session back. Try again.");
        return (access, refresh, double.TryParse(values.GetValueOrDefault("expires_in"),
                System.Globalization.CultureInfo.InvariantCulture, out var seconds) ? seconds : 3600);
    }

    public async Task SignOutAsync()
    {
        if (session is { } current && CloudConfig.Url is { } baseUrl)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Url(baseUrl, "auth/v1/logout"));
            request.Headers.Add("apikey", CloudConfig.AnonKey);
            request.Headers.Add("Authorization", $"Bearer {current.AccessToken}");
            try { (await Http.SendAsync(request)).Dispose(); } catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { }
        }
        Session = null;
        SetOrg(null);
        SessionStore.Delete();
        SyncEngine.Shared.Reset();
    }

    // MARK: - Orgs

    public async Task CreateOrgAsync(string name)
    {
        await Rest("POST", "rest/v1/rpc/create_org", json: new { name });
        await FetchOrg();
        SyncEngine.Shared.NoteOrgChanged();
    }

    public async Task JoinOrgAsync(string code)
    {
        await Rest("POST", "rest/v1/rpc/accept_invite", json: new { invite_code = code });
        await FetchOrg();
        SyncEngine.Shared.NoteOrgChanged();
    }

    // Removes the caller's own membership row (policy members_delete_owner_or_self). Owners cannot
    // leave: the UI hides the button, and this refuses too, so a team is never left without one.
    public async Task LeaveOrgAsync()
    {
        if (org is not { } current || session is not { } me) throw new CloudError("Join a team first.");
        if (current.IsOwner) throw new CloudError("Owners can't leave their team.");
        await Rest("DELETE", "rest/v1/org_members",
                   [("org_id", $"eq.{current.Id}"), ("user_id", $"eq.{me.UserID}")], prefer: "return=minimal");
        SetOrg(null);
        SyncEngine.Shared.NoteOrgChanged();
    }

    // Issues a code for one teammate's email — the code alone is inert without it (policies.sql).
    // Handing it over is the inviter's job; nothing is emailed.
    public async Task<string> CreateInviteAsync(string email)
    {
        if (org is not { } current || session is not { } me) throw new CloudError("Join a team first.");
        var code = NewInviteCode();
        await Rest("POST", "rest/v1/invites", json: new[]
        {
            new Dictionary<string, string>
            {
                ["org_id"] = current.Id.ToString(),
                ["email"] = email,
                ["code"] = code,
                ["invited_by"] = me.UserID.ToString(),
                ["expires_at"] = Iso(DateTime.UtcNow.AddDays(14)),
            },
        }, prefer: "return=minimal");
        return code;
    }

    // Owner only; the server enforces it. A non-owner's PATCH matches no rows and still answers
    // 204, so the UI never offers this to anyone else.
    public async Task RenameOrgAsync(string name)
    {
        var trimmed = name.Trim();
        if (org is not { } current) throw new CloudError("Join a team first.");
        if (trimmed.Length == 0) throw new CloudError("Give the team a name.");
        await Rest("PATCH", "rest/v1/orgs", [("id", $"eq.{current.Id}")], new { name = trimmed }, "return=minimal");
        if (org?.Id == current.Id) Org = current with { Name = trimmed };
    }

    // The roster, which also feeds the recognizer: teammates' names are the words most worth
    // spelling right. Kept on the client so it works without the Team page ever being opened.
    public async Task RefreshRosterAsync()
    {
        if (org is not { } current) return;
        var data = await Rest("GET", "rest/v1/org_members", [
            ("org_id", $"eq.{current.Id}"),
            ("select", "user_id,display_name,role,joined_at,users(email,display_name)"),
            ("order", "joined_at.asc"),
        ]);
        var rows = OrgMember.ParseList(data);
        if (org?.Id != current.Id) return;
        Roster = rows;
        AppSettings.Shared.RosterNames = rows.Select(r => r.DisplayName).ToList();
    }

    public async Task<List<string>> DictionaryWordsAsync(Guid userID)
    {
        var data = await Rest("GET", "rest/v1/dictionary_words", [
            ("user_id", $"eq.{userID}"), ("select", "word"), ("order", "word.asc"),
        ]);
        return JsonSerializer.Deserialize<List<WordRow>>(data, Json)!.Select(r => r.Word).ToList();
    }

    record WordRow([property: JsonPropertyName("word")] string Word);

    public async Task UpsertDictionaryWordsAsync(IReadOnlyList<string> words)
    {
        if (session is not { } me || words.Count == 0) return;
        await Rest("POST", "rest/v1/dictionary_words",
                   json: words.Select(w => new Dictionary<string, string> { ["user_id"] = me.UserID.ToString(), ["word"] = w }),
                   prefer: "resolution=merge-duplicates,return=minimal");
    }

    public async Task DeleteDictionaryWordsAsync(IReadOnlyList<string> words)
    {
        if (session is not { } me || words.Count == 0) return;
        await Rest("DELETE", "rest/v1/dictionary_words",
                   [("user_id", $"eq.{me.UserID}"), ("word", DictionaryWords.InList(words))], prefer: "return=minimal");
    }

    // Which org this account belongs to, if any. Safe to call repeatedly; failures leave `Org` as it
    // was and are logged rather than shown.
    public async Task RefreshOrgAsync()
    {
        try { await FetchOrg(); }
        catch (Exception e) { Log.Line($"cloud org fetch failed: {e.Message}"); }
    }

    // Throwing form for create/join: their RPC has already committed, so a failed fetch must reach
    // the caller or the form stays up with `Org` null and a second tap creates a duplicate.
    async Task FetchOrg()
    {
        if (session is not { } me) return;
        var data = await Rest("GET", "rest/v1/org_members", [
            ("user_id", $"eq.{me.UserID}"),
            ("select", "role,orgs(id,name)"),
            ("order", "joined_at.asc"),
            ("limit", "1"),
        ]);
        var rows = JsonSerializer.Deserialize<List<OrgRow>>(data, Json)!;
        SetOrg(rows.FirstOrDefault() is { } row ? new CloudOrg(row.Orgs.Id, row.Orgs.Name, row.Role) : null);
        if (org != null)
        {
            try { await RefreshRosterAsync(); }
            catch (Exception e) { Log.Line($"cloud roster fetch failed: {e.Message}"); }
        }
    }

    record OrgRow(
        [property: JsonPropertyName("role")] string Role,
        [property: JsonPropertyName("orgs")] OrgRef Orgs);
    record OrgRef(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("name")] string Name);

    // The one place `Org` changes, so the roster and the names it feeds the recognizer never
    // outlive the team they came from.
    void SetOrg(CloudOrg? next)
    {
        if (next?.Id != org?.Id)
        {
            Roster = [];
            AppSettings.Shared.RosterNames = [];
        }
        Org = next;
    }

    // MARK: - Data

    public async Task<List<LeaderboardRow>> LeaderboardAsync(string period)
    {
        if (org is not { } current) return [];
        var data = await Rest("GET", "rest/v1/leaderboard", [
            ("org_id", $"eq.{current.Id}"),
            ("period", $"eq.{period}"),
            ("select", "user_id,display_name,words,wpm,day_streak"),
            ("order", "words.desc"),
        ]);
        return JsonSerializer.Deserialize<List<LeaderboardRow>>(data, Json)!;
    }

    // Batch upsert keyed on the client-minted entry UUID, so retries are free and a push can never
    // duplicate a dictation.
    public async Task UpsertDictationsAsync(List<Dictionary<string, object>> rows)
    {
        if (rows.Count == 0) return;
        await Rest("POST", "rest/v1/dictations", json: rows, prefer: "resolution=merge-duplicates,return=minimal");
    }

    public async Task UpsertTextsAsync(List<Dictionary<string, object>> rows)
    {
        if (rows.Count == 0) return;
        await Rest("POST", "rest/v1/dictation_texts", json: rows, prefer: "resolution=merge-duplicates,return=minimal");
    }

    // MARK: - Plumbing

    // Who the stored session belongs to, read straight from disk, so `--cloud-check` can ask without
    // starting the client's state.
    public static string? StoredSessionEmail() => SessionStore.Load()?.Email;

    // 8 characters from an alphabet with no 0/O, 1/I/L — a code someone reads out loud.
    public static string NewInviteCode()
    {
        const string alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
        return string.Create(8, alphabet, (span, a) =>
        {
            for (var i = 0; i < span.Length; i++) span[i] = a[RandomNumberGenerator.GetInt32(a.Length)];
        });
    }

    // What PostgREST takes for a timestamptz: UTC, millisecond precision, a trailing Z.
    public static string Iso(DateTime date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");

    // Built by hand because a `+` left raw in a query value is read by PostgREST as a space, so a word
    // like "C++" would match the wrong row. EscapeDataString writes every real plus as %2B.
    public static Uri Url(Uri baseUrl, string path, IEnumerable<(string Name, string Value)>? query = null)
    {
        var text = string.Join("&", (query ?? []).Select(q => $"{Uri.EscapeDataString(q.Name)}={Uri.EscapeDataString(q.Value)}"));
        return new Uri(baseUrl.GetLeftPart(UriPartial.Path).TrimEnd('/') + "/" + path + (text.Length > 0 ? "?" + text : ""));
    }

    Task<string> Auth(string endpoint, object json, IEnumerable<(string, string)>? query = null)
    {
        if (CloudConfig.Url is not { } baseUrl) throw new CloudError("Accounts aren't set up.");
        var request = new HttpRequestMessage(HttpMethod.Post, Url(baseUrl, $"auth/v1/{endpoint}", query));
        request.Headers.Add("apikey", CloudConfig.AnonKey);
        request.Content = Body(json);
        return Send(request);
    }

    async Task<string> Rest(string method, string path, IEnumerable<(string, string)>? query = null,
                            object? json = null, string? prefer = null)
    {
        if (CloudConfig.Url is not { } baseUrl) throw new CloudError("Accounts aren't set up.");
        var request = new HttpRequestMessage(new HttpMethod(method), Url(baseUrl, path, query));
        request.Headers.Add("apikey", CloudConfig.AnonKey);
        request.Headers.Add("Authorization", $"Bearer {await AccessToken()}");
        if (prefer != null) request.Headers.Add("Prefer", prefer);
        if (json != null) request.Content = Body(json);
        return await Send(request);
    }

    static StringContent Body(object json) => new(JsonSerializer.Serialize(json), Encoding.UTF8, "application/json");

    static async Task<string> Send(HttpRequestMessage request)
    {
        using (request)
        {
            HttpResponseMessage response;
            try { response = await Http.SendAsync(request); }
            // Offline is the ordinary case, and the framework's wording for it is a stack-trace phrase.
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
            {
                throw new CloudError("Couldn't reach the server. Check your connection.");
            }
            using (response)
            {
                var body = await response.Content.ReadAsStringAsync();
                if (!response.IsSuccessStatusCode)
                    throw CloudError.From(body, (int)response.StatusCode, request.RequestUri?.AbsolutePath ?? "?");
                return body;
            }
        }
    }

    // A valid bearer token, refreshed just before it expires. A refresh the server rejects means the
    // session is gone, so the app returns to signed out rather than wedging every request. Being
    // offline, rate limited or a 5xx keeps the session for the next try.
    async Task<string> AccessToken()
    {
        if (session is not { } current) throw new CloudError("Sign in first.");
        return current.ExpiresAt > DateTime.UtcNow.AddSeconds(60) ? current.AccessToken : await RefreshSession(current);
    }

    // One refresh shared by every caller that finds the token expired: GoTrue rotates refresh
    // tokens, so a second concurrent POST would get `refresh_token_already_used` and sign the
    // person out for nothing.
    async Task<string> RefreshSession(CloudSession current)
    {
        if (refreshTask is { } running) return await running;
        var task = refreshTask = PerformRefresh(current);
        try { return await task; }
        finally { refreshTask = null; }
    }

    async Task<string> PerformRefresh(CloudSession current)
    {
        try
        {
            var data = await Auth("token", new { refresh_token = current.RefreshToken }, [("grant_type", "refresh_token")]);
            try { Adopt(data, current.Email); }
            catch (JsonException) { throw new CloudError("That didn't work. Try again in a moment."); }
        }
        catch (CloudError e) when (EndsSession(e.Status))
        {
            Session = null;
            SetOrg(null);
            SessionStore.Delete();
            throw new CloudError("You've been signed out. Sign in again from Settings.");
        }
        return session?.AccessToken ?? throw new CloudError("Sign in first.");
    }

    // Any 4xx means the server looked at this refresh token and refused it, except the two that
    // say "try again": 408 and 429.
    static bool EndsSession(int? status) => status is >= 400 and < 500 and not 408 and not 429;

    record TokenResponse(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("refresh_token")] string RefreshToken,
        [property: JsonPropertyName("expires_in")] double ExpiresIn,
        [property: JsonPropertyName("user")] TokenUser User);
    record TokenUser(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("email")] string? Email);

    void Adopt(string tokenData, string fallbackEmail)
    {
        var token = JsonSerializer.Deserialize<TokenResponse>(tokenData, Json)!;
        Adopt(token.AccessToken, token.RefreshToken, token.ExpiresIn, token.User.Id, token.User.Email ?? fallbackEmail);
    }

    // The one place a session is built and stored. The OAuth redirect hands back three token values
    // in a URL fragment and no user object, so the identity arrives separately — which is why this
    // takes the pieces rather than a response body.
    void Adopt(string accessToken, string refreshToken, double expiresIn, Guid userID, string email)
    {
        var fresh = new CloudSession(accessToken, refreshToken, DateTime.UtcNow.AddSeconds(expiresIn), userID, email);
        Session = fresh;
        SessionStore.Save(fresh);
    }

    // Who a bare access token belongs to. Asked of the server rather than decoded out of the JWT:
    // reading identity out of a token this app has not verified is trusting a string.
    async Task<(Guid Id, string Email)> UserAsync(string accessToken)
    {
        if (CloudConfig.Url is not { } baseUrl) throw new CloudError("Accounts aren't set up.");
        var request = new HttpRequestMessage(HttpMethod.Get, Url(baseUrl, "auth/v1/user"));
        request.Headers.Add("apikey", CloudConfig.AnonKey);
        request.Headers.Add("Authorization", $"Bearer {accessToken}");
        var who = JsonSerializer.Deserialize<TokenUser>(await Send(request), Json)!;
        return (who.Id, who.Email ?? "");
    }

    // MARK: - Seams

    // The url scheme Supabase hands Google's result back through. Windows has no Info.plist for it:
    // the registry says "bisprblow:// URLs open this exe", and the copy that starts passes the URL to
    // the running one. Written every launch, so a moved install repairs itself.
    public static void RegisterUrlScheme()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{CloudConfig.CallbackScheme}");
            key.SetValue("", "URL:BisprBlow");
            key.SetValue("URL Protocol", "");
            using var command = key.CreateSubKey(@"shell\open\command");
            command.SetValue("", $"\"{Environment.ProcessPath}\" \"%1\"");
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            Log.Line($"cloud: url scheme registration failed: {e.Message}");
        }
    }

    // `--cloud-check`: whether accounts are switched on, and where they point. Worth a seam because
    // the answer used to depend on a hand-edited setting, with nothing printed either way.
    public static async Task<int> CheckCliAsync()
    {
        Console.WriteLine($"ready={CloudConfig.Ready}");
        Console.WriteLine($"url={CloudConfig.Url?.AbsoluteUri ?? "none"}");
        Console.WriteLine($"key={(CloudConfig.AnonKey.Length == 0 ? "none" : CloudConfig.AnonKey[..Math.Min(18, CloudConfig.AnonKey.Length)] + "…")}");
        Console.WriteLine($"callback={CloudConfig.CallbackURL}");
        Console.WriteLine($"session={(StoredSessionEmail() is { } email ? $"signed in as {email}" : "signed out")}");
        // Everything above is our own config and cannot tell you the project is unconfigured; these
        // are the probes that can. The tell is PGRST205: a table that exists but denies the anon role
        // answers `[]`, so a missing table and an RLS-denied one look nothing alike. Anon-key GETs
        // only — no session needed, and nothing here mails anybody.
        if (CloudConfig.Url is { } baseUrl && CloudConfig.Ready)
        {
            async Task<string> Get(string path, IEnumerable<(string, string)>? query = null)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, Url(baseUrl, path, query));
                request.Headers.Add("apikey", CloudConfig.AnonKey);
                try
                {
                    using var response = await Http.SendAsync(request);
                    return await response.Content.ReadAsStringAsync();
                }
                catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { return "no answer"; }
            }
            var settings = await Get("auth/v1/settings");
            var enabled = new[] { "google", "apple", "github", "email" }.Where(p => settings.Contains($"\"{p}\":true")).ToList();
            Console.WriteLine($"providers={(enabled.Count == 0 ? "none" : string.Join(",", enabled))}");
            // The real names, from db/schema.sql.
            foreach (var table in new[] { "users", "orgs", "org_members", "invites", "dictations", "dictation_texts", "leaderboard" })
            {
                var body = await Get($"rest/v1/{table}", [("select", "*"), ("limit", "1")]);
                Console.WriteLine($"table.{table}={(body.Contains("PGRST205") ? "MISSING" : "present")}");
            }
        }
        return 0;
    }
}

// One DPAPI-encrypted file holding the session JSON, in the Roaming folder next to settings.json:
// readable only by this Windows user, the Windows stand-in for the Mac's Keychain item.
static class SessionStore
{
    static readonly string FilePath = Path.Combine(AppPaths.Support, "cloud-session.bin");

    public static void Save(CloudSession session)
    {
        try
        {
            var sealedBytes = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(session), null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(FilePath, sealedBytes);
        }
        catch (Exception e) when (e is IOException or CryptographicException) { Log.Line($"cloud: session save failed: {e.Message}"); }
    }

    public static CloudSession? Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<CloudSession>(ProtectedData.Unprotect(File.ReadAllBytes(FilePath), null, DataProtectionScope.CurrentUser))
                : null;
        }
        // A file another Windows user (or a reinstall) wrote does not decrypt; that is just signed out.
        catch (Exception e) when (e is IOException or CryptographicException or JsonException) { return null; }
    }

    public static void Delete()
    {
        try { File.Delete(FilePath); } catch (IOException) { }
    }
}
