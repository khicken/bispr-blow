import Foundation

extension SelfCheck {
    // True when a redirect is not a session. Used for the shapes that must never become one.
    static func rejectsCallback(_ url: URL) -> Bool {
        do {
            _ = try CloudClient.tokens(fromCallback: url)
            return false
        } catch {
            return true
        }
    }

    // The pure halves of cloud sync: queue diffing, the rows that travel, and the state file. The
    // failure that matters is words leaving the machine on the stats path, or a state file from
    // another version resetting what has synced.
    static func checkCloudSync() {
        let a = UUID(), b = UUID(), c = UUID()

        // The queue is "what history has that the synced set does not", in history order.
        precondition(SyncEngine.pending([a, b, c], synced: []) == [a, b, c])
        precondition(SyncEngine.pending([a, b, c], synced: [b]) == [a, c])
        precondition(SyncEngine.pending([a, b, c], synced: [a, b, c]).isEmpty)
        precondition(SyncEngine.pending([], synced: [a]).isEmpty)

        // A metric row carries counts and timings — never the words. Same word count the Home
        // page shows, so the leaderboard and the stat card can never disagree.
        let entry = DictationEntry(id: a, date: Date(timeIntervalSince1970: 1_770_000_000),
                                   raw: "um hello there nice", cleaned: "Hello there. Nice.",
                                   appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                   provider: "local", durationSeconds: 2.5)
        let org = UUID()
        let row = SyncEngine.metricRow(entry, userID: c, orgID: org)
        precondition(row["id"] as? String == a.uuidString)
        precondition(row["user_id"] as? String == c.uuidString)
        precondition(row["org_id"] as? String == org.uuidString)
        precondition(row["word_count"] as? Int == 3)
        precondition(row["duration_seconds"] as? Double == 2.5)
        precondition((row["created_at"] as? String)?.hasSuffix("Z") == true)
        precondition(row["raw"] == nil && row["cleaned"] == nil, "transcript text on the stats path")
        // No org means the column is simply absent, and Postgres keeps it null.
        precondition(SyncEngine.metricRow(entry, userID: c, orgID: nil)["org_id"] == nil)
        // NaN or infinity would raise an uncatchable exception in JSONSerialization; NUL is refused
        // by Postgres. Both are cleaned on the way out, and only payload-shaped 4xx get split.
        let bad = DictationEntry(id: a, date: Date(), raw: "a\u{0000}b", cleaned: "c\u{0000}",
                                 appName: "x\u{0000}y", bundleID: "", provider: "",
                                 durationSeconds: .nan)
        let badRow = SyncEngine.metricRow(bad, userID: c, orgID: nil)
        precondition(badRow["duration_seconds"] as? Double == 0 && badRow["app_name"] as? String == "xy")
        precondition(SyncEngine.metricRow(bad, userID: c, orgID: nil)["org_id"] == nil)
        precondition(SyncEngine.finiteDuration(.infinity) == 0 && SyncEngine.finiteDuration(-1) == 0)
        precondition(JSONSerialization.isValidJSONObject([badRow]))
        precondition(SyncEngine.textRow(bad)["raw"] as? String == "ab")
        precondition(SyncEngine.isRowRejection(400) && SyncEngine.isRowRejection(422))
        precondition(!SyncEngine.isRowRejection(401) && !SyncEngine.isRowRejection(429)
                     && !SyncEngine.isRowRejection(503) && !SyncEngine.isRowRejection(nil))
        // Text is its own row against the same id, under its own opt-in.
        let text = SyncEngine.textRow(entry)
        precondition(text["dictation_id"] as? String == a.uuidString)
        precondition(text["raw"] as? String == "um hello there nice")
        precondition(text["cleaned"] as? String == "Hello there. Nice.")

        // The state file tolerates missing keys, so a file written by any other version of the
        // schema never resets the synced sets to "everything again" or crashes the decode.
        precondition(try! JSONDecoder().decode(SyncEngine.State.self, from: Data("{}".utf8)).metrics.isEmpty)
        let partial = try! JSONDecoder().decode(SyncEngine.State.self,
                                                from: Data(#"{"metrics":["\#(a.uuidString)"]}"#.utf8))
        precondition(partial.metrics == [a] && partial.texts.isEmpty)

        // The compiled-in project, which is what every installed copy uses: a typo here switches
        // accounts off for everyone but a machine with the defaults override set.
        precondition(URL(string: CloudConfig.defaultURL)?.scheme == "https", CloudConfig.defaultURL)
        precondition(CloudConfig.defaultAnonKey.hasPrefix("sb_publishable_"))
        precondition(CloudConfig.ready)

        // Google's redirect puts the tokens in the URL FRAGMENT, not the query, and an error arrives
        // the same way. The only part of the Google path checkable without a configured client.
        let good = URL(string: "bisprblow://auth-callback#access_token=abc&expires_in=3600"
                       + "&refresh_token=xyz&token_type=bearer")!
        let tokens = try! CloudClient.tokens(fromCallback: good)
        precondition(tokens.accessToken == "abc" && tokens.refreshToken == "xyz")
        precondition(tokens.expiresIn == 3600)

        // Query-string tokens are not a session: Supabase puts them in the fragment, and accepting
        // them from the query would accept a link anyone could have built.
        let query = URL(string: "bisprblow://auth-callback?access_token=abc&refresh_token=xyz")!
        precondition(rejectsCallback(query))

        // The server's own words survive: a provider that is not configured says so, and that
        // sentence is the whole diagnosis.
        let failed = URL(string: "bisprblow://auth-callback#error=invalid_request"
                         + "&error_description=Unsupported+provider%3A+provider+is+not+enabled")!
        do {
            _ = try CloudClient.tokens(fromCallback: failed)
            preconditionFailure("an error fragment must not read as a session")
        } catch {
            precondition(error.localizedDescription == "Unsupported provider: provider is not enabled",
                         error.localizedDescription)
        }

        // A fragment with an access token but no refresh token would build a session that cannot
        // outlive the hour, and the failure would land an hour later looking like something else.
        let half = URL(string: "bisprblow://auth-callback#access_token=abc")!
        precondition(rejectsCallback(half))

        checkTeamDictionary()

        // Invite codes: fixed length, an alphabet with no 0/O or 1/I/L, and no repeats in a batch.
        let codes = (0..<500).map { _ in CloudClient.newInviteCode() }
        precondition(Set(codes).count == codes.count)
        precondition(codes.allSatisfy { code in
            code.count == 8 && code.allSatisfy { "23456789ABCDEFGHJKMNPQRSTUVWXYZ".contains($0) }
        })
    }

    // Roster decoding, the dictionary diff, the `in.()` quoting and the vocabulary merge: the parts of
    // the Team page that can be wrong without any network.
    static func checkTeamDictionary() {
        // The roster's embedded `users` object, a member with `users` null, and a blank team name.
        let sample = """
        [{"user_id":"11111111-1111-1111-1111-111111111111","display_name":"Ada Lovelace","role":"owner",
          "joined_at":"2026-01-01T00:00:00Z","users":{"email":"ada@x.co","display_name":"Ada L"}},
         {"user_id":"22222222-2222-2222-2222-222222222222","display_name":"","role":"member",
          "joined_at":"2026-01-02T00:00:00Z","users":{"email":"bo@x.co","display_name":"Bo"}},
         {"user_id":"33333333-3333-3333-3333-333333333333","display_name":"","role":"member",
          "joined_at":"2026-01-03T00:00:00Z","users":null}]
        """
        let roster = try! JSONDecoder().decode([OrgMember].self, from: Data(sample.utf8))
        precondition(roster.count == 3)
        precondition(roster[0].isOwner && roster[0].email == "ada@x.co" && roster[0].displayName == "Ada Lovelace")
        precondition(!roster[1].isOwner && roster[1].displayName == "Bo")
        precondition(roster[2].email == nil && roster[2].displayName == "Teammate")

        // Clean: trimmed, no empties, capped at 200, unique ignoring case with the first spelling kept.
        let long = String(repeating: "x", count: 300)
        let cleaned = DictionaryWords.clean([" Claude ", "claude", "", "  ", "Vite", long, "a\u{0000}b"])
        precondition(cleaned == ["Claude", "Vite", String(repeating: "x", count: 200), "ab"], "\(cleaned)")

        // Diff against what this Mac last sent: new words go up, removed ones come down, and a
        // recased word is both. Words only another device sent are never in `synced`, so never deleted.
        let plan = DictionaryWords.plan(local: ["Vite", "Claude", "Zed"], synced: ["Vite", "claude", "Old"])
        precondition(plan.upsert == ["Claude", "Zed"], "\(plan.upsert)")
        precondition(plan.delete == ["Old", "claude"], "\(plan.delete)")
        let none = DictionaryWords.plan(local: ["a"], synced: ["a"])
        precondition(none.upsert.isEmpty && none.delete.isEmpty)

        // Importing skips what is already here, ignoring case, and repeats within their list.
        precondition(DictionaryWords.importable(theirs: ["vite", "Kubernetes", "kubernetes", "Zed"],
                                                mine: ["Vite", "zed"]) == ["Kubernetes"])

        // `in.()` quoting: every value quoted; commas, parentheses, quotes and backslashes are data.
        precondition(DictionaryWords.inList(["a", "b c"]) == #"in.("a","b c")"#)
        precondition(DictionaryWords.inList([#"say "hi""#]) == #"in.("say \"hi\"")"#)
        precondition(DictionaryWords.inList([#"a\b"#, "x,y", "f(x)"]) == #"in.("a\\b","x,y","f(x)")"#)
        // And it survives the trip into a URL: `+` is escaped (a raw one reads as a space server
        // side), `&` and `=` stay inside the one value.
        let base = URL(string: "https://x.co")!
        let url = CloudClient.url(base, "rest/v1/dictionary_words",
                                  [.init(name: "word", value: DictionaryWords.inList(["C++", "a&b=c"]))])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(items.count == 1 && items[0].value == #"in.("C++","a&b=c")"#, url.absoluteString)
        precondition(!url.absoluteString.contains("+") && !url.absoluteString.contains("&"))

        // Vocabulary: groups in priority order, deduped ignoring case, first spelling wins.
        let merged = AppSettings.mergedVocabulary(["Claude", " "], ["Ada", "vite"], ["ada", "Bo", "Vite"],
                                                  ["claude", "GitHub"])
        precondition(merged == ["Claude", "Ada", "vite", "Bo", "GitHub"], "\(merged)")

        // The state file written before words existed still decodes with an empty set.
        precondition(try! JSONDecoder().decode(SyncEngine.State.self, from: Data(#"{"metrics":[]}"#.utf8))
            .words.isEmpty)
    }

    // Accurate resolving to the same model as Fast is the trigger for offering the download, and it
    // is invisible from outside: `pick` falls through to the first installed model rather than
    // failing, so the setting moves and the writing does not change.
    static func checkAccurateResolution() {
        let fastOnly = ["Qwen3-0.6B-MLX-4bit"]
        precondition(LLMCleaner.pick(from: fastOnly, for: .accurate)
            == LLMCleaner.pick(from: fastOnly, for: .fast), "Accurate should collapse onto Fast here")

        let both = ["Qwen3-0.6B-MLX-4bit", "Qwen3-1.7B-MLX-8bit"]
        precondition(LLMCleaner.pick(from: both, for: .fast) == "Qwen3-0.6B-MLX-4bit")
        // The explicit "qwen3-1.7b" entry earning its place: without it the generic "qwen" matches
        // the 0.6b and the two modes collapse even with both models on disk.
        precondition(LLMCleaner.pick(from: both, for: .accurate) == "Qwen3-1.7B-MLX-8bit")

        precondition(LLMCleaner.pick(from: [], for: .accurate) == nil)
    }
}
