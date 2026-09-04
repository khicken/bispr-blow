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

        // Invite codes: fixed length, an alphabet with no 0/O or 1/I/L, and no repeats in a batch.
        let codes = (0..<500).map { _ in CloudClient.newInviteCode() }
        precondition(Set(codes).count == codes.count)
        precondition(codes.allSatisfy { code in
            code.count == 8 && code.allSatisfy { "23456789ABCDEFGHJKMNPQRSTUVWXYZ".contains($0) }
        })
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
