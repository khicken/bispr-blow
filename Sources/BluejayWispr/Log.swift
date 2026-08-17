import Foundation
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

/// The stamps between pressing the dictation key and the pill being live, all measured from the
/// same origin. A single number cannot tell a late start from a slow animation, and those need
/// opposite fixes — so the origin is the gesture edge and every later stage is reported against
/// it, in one line per dictation.
///
/// What each stage means:
/// - `onStart`: the callback hop out of the event tap and into `beginRecording`. Pure overhead.
/// - `pill`: the panel resized to the recording bar, i.e. the frame SwiftUI committed. This is
///   where the animation *starts*, not where it ends — `PillView.grow` is a 0.32s spring on top,
///   which is declared in code and does not need measuring.
/// - `session`: `transcriber.startSession` returned. `beginRecording` awaits it before opening
///   the mic, so this is the floor under `mic` and the two are worth seeing apart.
/// - `mic`: audio is actually being captured. Everything before it is spoken into nothing.
///
/// Only the push-to-talk path is traced; hands-free starts from the pill button are a different
/// gesture. A dictation whose mic never opened logs no line at all, which is itself the finding.
///
/// Main-thread only, and everything that calls it already is: the tap's run loop source is
/// attached to the main run loop, and the two later stages are `@MainActor`.
enum ActivationTrace {
    /// Named rather than counted, so adding a stage is one edit and a short dictation cannot
    /// emit a half-filled line that reads like a complete one.
    private static let stages = ["onStart", "pill", "session", "mic"]

    private static var edge: TimeInterval?
    private static var marks: [(stage: String, ms: Int)] = []

    /// The gesture edge. Stamped *before* `onStart` is called, so the callback hop is inside the
    /// measurement rather than invisible behind it.
    static func begin() {
        edge = ProcessInfo.processInfo.systemUptime
        marks = []
    }

    /// Records a stage once. Repeat marks for a stage are dropped, because the pill's size can
    /// settle more than once per state and only the first crossing is the latency.
    static func mark(_ stage: String) {
        guard let edge, !marks.contains(where: { $0.stage == stage }) else { return }
        marks.append((stage, Int((ProcessInfo.processInfo.systemUptime - edge) * 1000)))
        guard marks.count == stages.count else { return }
        logLine("activation " + marks.map { "\($0.stage)=\($0.ms)ms" }.joined(separator: " "))
        Self.edge = nil
    }
}
