import Foundation
import os

// One logger for the app's diagnostics, queryable with
// `/usr/bin/log show --predicate 'subsystem == "ai.getbluejay.bisprblow"' --last 1h` (absolute path:
// the shell profile shadows the bare name). Everything is interpolated as `.public` on purpose —
// NSLog and Logger's default privacy redact arguments, so every line read back as `<private>`.
private let appLog = Logger(subsystem: "ai.getbluejay.bisprblow", category: "app")

// `notice` and not `info`: `log show` drops info-level lines unless you pass `--info`,
// which is one more way for these numbers to look like they were never written.
func logLine(_ message: String) {
    appLog.notice("\(message, privacy: .public)")
}

// The stamps between pressing the dictation key and the pill being live, all from the same origin:
// a single number cannot tell a late start from a slow animation, and those need opposite fixes.
//
// - `onStart`: the callback hop out of the event tap into `beginRecording`. Pure overhead.
// - `pill`: the panel resized to the recording bar, i.e. the frame SwiftUI committed — where the
//   animation starts, not where it ends (`PillView.grow` is a 0.32s spring on top).
// - `session`: `transcriber.startSession` returned; the floor under `mic`.
// - `mic`: audio is actually being captured. Everything before it is spoken into nothing.
//
// Only the push-to-talk path is traced. A dictation whose mic never opened logs no line at all,
// which is itself the finding. Main-thread only, and every caller already is.
enum ActivationTrace {
    // Named rather than counted, so adding a stage is one edit and a short dictation cannot
    // emit a half-filled line that reads like a complete one.
    private static let stages = ["onStart", "pill", "session", "mic"]

    private static var edge: TimeInterval?
    private static var marks: [(stage: String, ms: Int)] = []

    // The gesture edge. Stamped *before* `onStart` is called, so the callback hop is inside the
    // measurement rather than invisible behind it.
    static func begin() {
        edge = ProcessInfo.processInfo.systemUptime
        marks = []
    }

    // Records a stage once. Repeat marks for a stage are dropped, because the pill's size can
    // settle more than once per state and only the first crossing is the latency.
    static func mark(_ stage: String) {
        guard let edge, !marks.contains(where: { $0.stage == stage }) else { return }
        marks.append((stage, Int((ProcessInfo.processInfo.systemUptime - edge) * 1000)))
        guard marks.count == stages.count else { return }
        logLine("activation " + marks.map { "\($0.stage)=\($0.ms)ms" }.joined(separator: " "))
        Self.edge = nil
    }
}
