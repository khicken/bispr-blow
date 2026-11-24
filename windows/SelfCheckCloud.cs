using System.Text.Json;

namespace BisprBlow;

// The cloud pieces of `--self-check` that need no network: the sign-in callback's shapes, cloud sync's
// queue and rows, the team dictionary, and the version compare. The failure that matters is words
// leaving the machine on the stats path, or a state file from another version resetting what has synced.
static class SelfCheckCloud
{
    public static void Run()
    {
        Sync();
        TeamDictionary();
        VersionCompare();
    }

    // True when a redirect is not a session. Used for the shapes that must never become one.
    static bool RejectsCallback(Uri url)
    {
        try
        {
            CloudClient.Tokens(url);
            return false;
        }
        catch (CloudError) { return true; }
    }

    static bool Is<T>(object? value, T expected) => value is T actual && EqualityComparer<T>.Default.Equals(actual, expected);

    static void Sync()
    {
        Guid a = Guid.NewGuid(), b = Guid.NewGuid(), c = Guid.NewGuid();

        // The queue is "what history has that the synced set does not", in history order.
        Check.That(SyncEngine.Pending([a, b, c], new HashSet<Guid>()).SequenceEqual([a, b, c]));
        Check.That(SyncEngine.Pending([a, b, c], new HashSet<Guid> { b }).SequenceEqual([a, c]));
        Check.That(SyncEngine.Pending([a, b, c], new HashSet<Guid> { a, b, c }).Count == 0);
        Check.That(SyncEngine.Pending([], new HashSet<Guid> { a }).Count == 0);

        // A metric row carries counts and timings — never the words. Same word count the Home
        // page shows, so the leaderboard and the stat card can never disagree.
        var entry = new DictationEntry(a, DateTimeOffset.FromUnixTimeSeconds(1_770_000_000).UtcDateTime,
                                       "um hello there nice", "Hello there. Nice.", "Slack", "slack", "local", 2.5);
        var org = Guid.NewGuid();
        var row = SyncEngine.MetricRow(entry, c, org);
        Check.That(Is(row["id"], a.ToString()));
        Check.That(Is(row["user_id"], c.ToString()));
        Check.That(Is(row["org_id"], org.ToString()));
        Check.That(Is(row["word_count"], 3));
        Check.That(Is(row["duration_seconds"], 2.5));
        Check.That(row["created_at"] is string created && created.EndsWith('Z'));
        Check.That(!row.ContainsKey("raw") && !row.ContainsKey("cleaned"), "transcript text on the stats path");
        // No org means the column is simply absent, and Postgres keeps it null.
        Check.That(!SyncEngine.MetricRow(entry, c, null).ContainsKey("org_id"));
        // NaN or infinity would make the JSON writer throw; NUL is refused by Postgres. Both are
        // cleaned on the way out, and only payload-shaped 4xx get split.
        var bad = new DictationEntry(a, DateTime.UtcNow, "a\0b", "c\0", "x\0y", "", "", double.NaN);
        var badRow = SyncEngine.MetricRow(bad, c, null);
        Check.That(Is(badRow["duration_seconds"], 0.0) && Is(badRow["app_name"], "xy"));
        Check.That(!SyncEngine.MetricRow(bad, c, null).ContainsKey("org_id"));
        Check.That(SyncEngine.FiniteDuration(double.PositiveInfinity) == 0 && SyncEngine.FiniteDuration(-1) == 0);
        var serialized = true;
        try { JsonSerializer.Serialize(new[] { badRow }); } catch (ArgumentException) { serialized = false; }
        Check.That(serialized);
        Check.That(Is(SyncEngine.TextRow(bad)["raw"], "ab"));
        Check.That(SyncEngine.IsRowRejection(400) && SyncEngine.IsRowRejection(422));
        Check.That(!SyncEngine.IsRowRejection(401) && !SyncEngine.IsRowRejection(429)
                   && !SyncEngine.IsRowRejection(503) && !SyncEngine.IsRowRejection(null));
        // Text is its own row against the same id, under its own opt-in.
        var text = SyncEngine.TextRow(entry);
        Check.That(Is(text["dictation_id"], a.ToString()));
        Check.That(Is(text["raw"], "um hello there nice"));
        Check.That(Is(text["cleaned"], "Hello there. Nice."));

        // The state file tolerates missing keys, so a file written by any other version of the
        // schema never resets the synced sets to "everything again" or fails the load.
        Check.That(JsonSerializer.Deserialize<SyncEngine.State>("{}")!.Metrics.Count == 0);
        var partial = JsonSerializer.Deserialize<SyncEngine.State>($$"""{"metrics":["{{a}}"]}""")!;
        Check.That(partial.Metrics.SetEquals([a]) && partial.Texts.Count == 0);

        // The compiled-in project, which is what every installed copy uses: a typo here switches
        // accounts off for everyone but a machine with the override set.
        Check.Equal(new Uri(CloudConfig.DefaultURL).Scheme, "https");
        Check.That(CloudConfig.DefaultAnonKey.StartsWith("sb_publishable_"));
        Check.That(CloudConfig.Ready);

        // Google's redirect puts the tokens in the URL FRAGMENT, not the query, and an error arrives
        // the same way. The only part of the Google path checkable without a configured client.
        var good = new Uri("bisprblow://auth-callback#access_token=abc&expires_in=3600&refresh_token=xyz&token_type=bearer");
        var tokens = CloudClient.Tokens(good);
        Check.That(tokens.AccessToken == "abc" && tokens.RefreshToken == "xyz");
        Check.Equal(tokens.ExpiresIn, 3600.0);

        // Query-string tokens are not a session: Supabase puts them in the fragment, and accepting
        // them from the query would accept a link anyone could have built.
        Check.That(RejectsCallback(new Uri("bisprblow://auth-callback?access_token=abc&refresh_token=xyz")));

        // The server's own words survive: a provider that is not configured says so, and that
        // sentence is the whole diagnosis.
        var failed = new Uri("bisprblow://auth-callback#error=invalid_request"
                             + "&error_description=Unsupported+provider%3A+provider+is+not+enabled");
        try
        {
            CloudClient.Tokens(failed);
            Check.That(false, "an error fragment must not read as a session");
        }
        catch (CloudError e) { Check.Equal(e.Message, "Unsupported provider: provider is not enabled"); }

        // A fragment with an access token but no refresh token would build a session that cannot
        // outlive the hour, and the failure would land an hour later looking like something else.
        Check.That(RejectsCallback(new Uri("bisprblow://auth-callback#access_token=abc")));

        // Invite codes: fixed length, an alphabet with no 0/O or 1/I/L, and no repeats in a batch.
        var codes = Enumerable.Range(0, 500).Select(_ => CloudClient.NewInviteCode()).ToList();
        Check.That(codes.Distinct().Count() == codes.Count);
        Check.That(codes.All(code => code.Length == 8 && code.All("23456789ABCDEFGHJKMNPQRSTUVWXYZ".Contains)));
    }

    // Roster decoding, the dictionary diff, the `in.()` quoting and the vocabulary merge: the parts of
    // the Team page that can be wrong without any network.
    static void TeamDictionary()
    {
        // The roster's embedded `users` object, a member with `users` null, and a blank team name.
        const string sample = """
            [{"user_id":"11111111-1111-1111-1111-111111111111","display_name":"Ada Lovelace","role":"owner",
              "joined_at":"2026-01-01T00:00:00Z","users":{"email":"ada@x.co","display_name":"Ada L"}},
             {"user_id":"22222222-2222-2222-2222-222222222222","display_name":"","role":"member",
              "joined_at":"2026-01-02T00:00:00Z","users":{"email":"bo@x.co","display_name":"Bo"}},
             {"user_id":"33333333-3333-3333-3333-333333333333","display_name":"","role":"member",
              "joined_at":"2026-01-03T00:00:00Z","users":null}]
            """;
        var roster = OrgMember.ParseList(sample);
        Check.Equal(roster.Count, 3);
        Check.That(roster[0].IsOwner && roster[0].Email == "ada@x.co" && roster[0].DisplayName == "Ada Lovelace");
        Check.That(!roster[1].IsOwner && roster[1].DisplayName == "Bo");
        Check.That(roster[2].Email == null && roster[2].DisplayName == "Teammate");

        // Clean: trimmed, no empties, capped at 200, unique ignoring case with the first spelling kept.
        var cleaned = DictionaryWords.Clean([" Claude ", "claude", "", "  ", "Vite", new string('x', 300), "a\0b"]);
        Check.That(cleaned.SequenceEqual(["Claude", "Vite", new string('x', 200), "ab"]), string.Join("|", cleaned));

        // Diff against what this PC last sent: new words go up, removed ones come down, and a
        // recased word is both. Words only another device sent are never in `synced`, so never deleted.
        var plan = DictionaryWords.Plan(["Vite", "Claude", "Zed"], new HashSet<string> { "Vite", "claude", "Old" });
        Check.That(plan.Upsert.SequenceEqual(["Claude", "Zed"]), string.Join("|", plan.Upsert));
        Check.That(plan.Delete.SequenceEqual(["Old", "claude"]), string.Join("|", plan.Delete));
        var none = DictionaryWords.Plan(["a"], new HashSet<string> { "a" });
        Check.That(none.Upsert.Count == 0 && none.Delete.Count == 0);

        // Importing skips what is already here, ignoring case, and repeats within their list.
        Check.That(DictionaryWords.Importable(["vite", "Kubernetes", "kubernetes", "Zed"], ["Vite", "zed"]).SequenceEqual(["Kubernetes"]));

        // `in.()` quoting: every value quoted; commas, parentheses, quotes and backslashes are data.
        Check.Equal(DictionaryWords.InList(["a", "b c"]), """in.("a","b c")""");
        Check.Equal(DictionaryWords.InList(["say \"hi\""]), """in.("say \"hi\"")""");
        Check.Equal(DictionaryWords.InList(["a\\b", "x,y", "f(x)"]), """in.("a\\b","x,y","f(x)")""");
        // And it survives the trip into a URL: `+` is escaped (a raw one reads as a space server
        // side), `&` and `=` stay inside the one value.
        var url = CloudClient.Url(new Uri("https://x.co"), "rest/v1/dictionary_words",
                                  [("word", DictionaryWords.InList(["C++", "a&b=c"]))]);
        var items = System.Web.HttpUtility.ParseQueryString(url.Query);
        Check.That(items.Count == 1 && items["word"] == """in.("C++","a&b=c")""", url.AbsoluteUri);
        Check.That(!url.AbsoluteUri.Contains('+') && !url.AbsoluteUri.Contains('&'));

        // Vocabulary: groups in priority order, deduped ignoring case, first spelling wins.
        var merged = AppSettings.MergedVocabulary(["Claude", " "], ["Ada", "vite"], ["ada", "Bo", "Vite"], ["claude", "GitHub"]);
        Check.That(merged.SequenceEqual(["Claude", "Ada", "vite", "Bo", "GitHub"]), string.Join("|", merged));

        // The state file written before words existed still decodes with an empty set.
        Check.That(JsonSerializer.Deserialize<SyncEngine.State>("""{"metrics":[]}""")!.Words.Count == 0);
    }

    // Numeric per component, so 0.10.0 beats 0.9.0; a tag it cannot read never nags.
    static void VersionCompare()
    {
        Check.That(UpdateChecker.IsNewer("v0.3.0", "0.2.0"));
        Check.That(UpdateChecker.IsNewer("v0.10.0", "0.9.0"));
        Check.That(UpdateChecker.IsNewer("v0.2.1", "0.2"));
        Check.That(!UpdateChecker.IsNewer("v0.2.0", "0.2.0"));
        Check.That(!UpdateChecker.IsNewer("v0.2.0", "0.2"));
        Check.That(!UpdateChecker.IsNewer("v0.1.9", "0.2.0"));
        Check.That(!UpdateChecker.IsNewer("nightly", "0.2.0"));
        Check.That(!UpdateChecker.IsNewer("v0.3.0", "dev"));
    }
}
