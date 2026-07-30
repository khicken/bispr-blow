import os

/// One logger for the app's diagnostics, queryable with
/// `/usr/bin/log show --predicate 'subsystem == "ai.getbluejay.wispr"' --last 1h`.
///
/// Everything is interpolated as `.public` on purpose. NSLog redacts its arguments in the
/// unified log, and `Logger`'s default interpolation privacy does the same, so every line
/// this app ever logged read back as `<private>` — including the timings we needed.
/// Use the absolute path for `log`: the shell profile shadows the bare name.
private let appLog = Logger(subsystem: "ai.getbluejay.wispr", category: "app")

/// `notice` and not `info`: `log show` drops info-level lines unless you pass `--info`,
/// which is one more way for these numbers to look like they were never written.
func logLine(_ message: String) {
    appLog.notice("\(message, privacy: .public)")
}
