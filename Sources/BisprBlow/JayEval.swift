import AppKit
import Foundation

// What `--dump-elements` writes, and one of the two shapes `--jay-eval` reads a recorded screen from.
struct ScreenDump: Codable {
    let trusted: Bool
    let ms: Int
    let snapshot: ScreenSnapshot
}

struct JayEvalCase: Codable {
    struct Expect: Codable {
        let intent: JayIntent
        let actions: [String]   // JayAction.key strings, any one matches; empty scores the intent alone
        let text: String?
        let risky: Bool?
        let task: Bool?
    }
    let id: String
    let command: String
    let snapshot: String        // relative to the cases file
    let expect: Expect
    let live: Bool?
}

enum JayEval {
    // Not TextEdit: its new documents autosave to iCloud, so live typing leaves real files behind.
    static let liveBundleIDs: Set<String> = ["com.apple.calculator"]
    static let accuracyTarget = 0.95
    static let projectedTailTargetMs = 500
    static let taskDoneTarget = 0.8
    static let medianFraction = 0.5
    static let tailFraction = 0.9
    static let activateTimeout: TimeInterval = 2
    static let activatePoll: TimeInterval = 0.05
    private static let millisecondsPerSecond = 1000.0

    struct Spread: Encodable { let p50: Int; let p90: Int }
    struct TaskStats: Encodable { let cases: Int; let done: Int }

    struct Row: Encodable {
        let id: String
        let intent: String
        let got: String
        let sure: Bool
        let confidence: Double
        let right: Bool
        let decideMs: Int
        let jevMs: Int
        let calls: Int
        let runnerUp: String?
        let shortlist: [String]
        var outcome: String?
        var actMs: Int?
        var steps: [String]?
        var clipboardKept: Bool?
    }

    struct Report: Encodable {
        let cases: Int
        let right: Int
        let accuracy: Double
        let sure: Int
        let sureRight: Int
        let sureWrong: Int
        let asked: Int
        let askedContainsRight: Int
        let riskyExpected: Int
        let riskyMissed: Int
        let calls: Int
        let decideMs: Spread
        let jevMs: Spread
        let rerankMs: Spread
        let projectedEndToActionMs: Spread
        let tasks: TaskStats
        let rows: [Row]
    }

    private struct Scored {
        var row: Row
        let rerankMs: Int
        let wasDecided: Bool
        let wasAsked: Bool
        let askedContainsRight: Bool
        let expectsRisky: Bool
        let missedRisky: Bool
        var ranTask = false
        var finishedTask = false
    }

    static func run(casesURL: URL, reportURL: URL, isLive: Bool, liveBundleIDs: Set<String>) async {
        let cases: [JayEvalCase]
        do { cases = try JSONDecoder().decode([JayEvalCase].self, from: Data(contentsOf: casesURL)) }
        catch {
            print("jay-eval: cases unreadable error=\(error.localizedDescription)")
            return
        }
        let apps = InstalledApps.all()
        var scored: [Scored] = []
        for evalCase in cases {
            do { scored.append(try await score(evalCase, casesURL: casesURL, apps: apps, liveBundleIDs: isLive ? liveBundleIDs : [])) }
            catch Jev.Failure.noKey { print("jay-eval: stopped, no TypeSafe key in the Keychain"); return }
            catch Jev.Failure.keyRejected { print("jay-eval: stopped, TypeSafe rejected the Keychain key"); return }
            catch { scored.append(failCase(evalCase, reason: "unexpected")) }
        }
        let report = buildReport(from: scored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(report).write(to: reportURL, options: .atomic) }
        catch { print("jay-eval: report unwritable error=\(error.localizedDescription)") }
        let line = summarize(report)
        print(line)
        logLine(line)
    }

    private static func score(_ evalCase: JayEvalCase, casesURL: URL, apps: [InstalledApp], liveBundleIDs: Set<String>) async throws -> Scored {
        let snapshotURL = casesURL.deletingLastPathComponent().appendingPathComponent(evalCase.snapshot)
        guard let screen = try? loadSnapshot(Data(contentsOf: snapshotURL)) else { return failCase(evalCase, reason: "snapshotUnreadable") }
        do {
            if evalCase.live == true, liveBundleIDs.contains(screen.bundleID) {
                return try await scoreLive(evalCase, bundleID: screen.bundleID, apps: apps)
            }
            let started = ProcessInfo.processInfo.systemUptime
            // JayController runs a chained command a step at a time
            let steps = VoiceCommand.steps(in: VoiceCommand.withoutLeadingJoint(evalCase.command))
            let decision = try await JayDecide.decide(steps.first ?? evalCase.command, screen: screen, apps: apps)
            return scoreDecision(evalCase, decision: decision, isChained: steps.count > 1, screen: screen, decideMs: elapsedMs(since: started))
        } catch let failure as Jev.Failure {
            guard case .badReply = failure else { throw failure }
            return failCase(evalCase, reason: "badReply")
        } catch {
            return failCase(evalCase, reason: "jevUnreachable")
        }
    }

    @MainActor private static func scoreLive(_ evalCase: JayEvalCase, bundleID: String, apps: [InstalledApp]) async throws -> Scored {
        guard let app = await bringToFront(bundleID) else { return failCase(evalCase, reason: "appNotFront") }
        let screen = await ScreenElements.snapshot(app: app)
        let started = ProcessInfo.processInfo.systemUptime
        let decision = try await JayDecide.decide(evalCase.command, screen: screen, apps: apps)
        var result = scoreDecision(evalCase, decision: decision, isChained: false, screen: screen, decideMs: elapsedMs(since: started))
        let clipboard = NSPasteboard.general.string(forType: .string)
        let actStarted = ProcessInfo.processInfo.systemUptime
        if evalCase.expect.task == true {
            // a step that leaves the app under test ends the task, so a wrong pick cannot keep acting elsewhere
            let task = await JayTask.run(goal: evalCase.command, first: decision, apps: apps,
                                         isCurrent: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID },
                                         report: { _ in }, confirm: { _ in false })
            result.ranTask = true
            result.finishedTask = task.outcome == .done
            result.row.outcome = task.outcome.rawValue
            result.row.steps = task.actionKeys
        } else {
            result.row.outcome = await actOnDecision(decision, isRight: result.row.right, command: evalCase.command, screen: screen)
        }
        if result.row.outcome != nil { result.row.actMs = elapsedMs(since: actStarted) }
        // the user's clipboard is put back whatever a wrong step did to it, and the row says so
        result.row.clipboardKept = NSPasteboard.general.string(forType: .string) == clipboard
        if result.row.clipboardKept == false, let clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
        }
        return result
    }

    @MainActor private static func actOnDecision(_ decision: JayDecision, isRight: Bool, command: String, screen: ScreenSnapshot) async -> String? {
        guard let action = decision.action else { return nil }
        guard decision.isSure else { return "asked" }
        // a wrong pick can be anything system-wide (lock screen, dark mode), so live mode only performs right ones
        guard isRight else { return "skippedWrong" }
        return await JayExecutor.run(action, command: command, isWakeListening: false, screen: screen, confirmed: false).rawValue
    }

    @MainActor private static func bringToFront(_ bundleID: String) async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + activateTimeout
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            try? await Task.sleep(for: .seconds(activatePoll))
        }
        try? await Task.sleep(for: .seconds(JayTask.settleDelay))
        return app
    }

    private static func scoreDecision(_ evalCase: JayEvalCase, decision: JayDecision, isChained: Bool, screen: ScreenSnapshot, decideMs: Int) -> Scored {
        let expect = evalCase.expect
        let row = Row(id: evalCase.id, intent: decision.intent.rawValue, got: decision.action?.key ?? "none",
                      sure: decision.isSure, confidence: decision.confidence, right: isRight(decision, expect: expect, isChained: isChained),
                      decideMs: decideMs, jevMs: decision.timings.jevMs, calls: decision.timings.calls,
                      runnerUp: decision.runnerUp?.key, shortlist: decision.shortlist.map(\.key))
        return Scored(row: row, rerankMs: decision.timings.rerankMs, wasDecided: true,
                      wasAsked: !decision.isSure && !decision.shortlist.isEmpty,
                      askedContainsRight: !decision.isSure && decision.shortlist.contains { expect.actions.contains($0.key) },
                      expectsRisky: expect.risky == true,
                      missedRisky: expect.risky == true && runsUnasked(decision, command: evalCase.command))
    }

    // Only a sure pick runs without asking. Its runner-up runs after it changed nothing, and
    // runWithFallback checks that one itself; an unsure pick is always asked about.
    static func runsUnasked(_ decision: JayDecision, command: String) -> Bool {
        guard decision.isSure, let action = decision.action else { return false }
        return !JayExecutor.isRisky(action, command: command, isWakeListening: false)
    }

    private static func failCase(_ evalCase: JayEvalCase, reason: String) -> Scored {
        let row = Row(id: evalCase.id, intent: "error", got: reason, sure: false, confidence: 0, right: false, decideMs: 0, jevMs: 0, calls: 0,
                      runnerUp: nil, shortlist: [])
        return Scored(row: row, rerankMs: 0, wasDecided: false, wasAsked: false, askedContainsRight: false,
                      expectsRisky: evalCase.expect.risky == true, missedRisky: false)
    }

    private static func buildReport(from scored: [Scored]) -> Report {
        let rows = scored.map(\.row)
        let decided = scored.filter(\.wasDecided)
        let sure = rows.filter(\.sure)
        let tasks = scored.filter(\.ranTask)
        let rightCount = rows.filter(\.right).count
        return Report(cases: rows.count, right: rightCount, accuracy: rows.isEmpty ? 0 : Double(rightCount) / Double(rows.count),
                      sure: sure.count, sureRight: sure.filter(\.right).count, sureWrong: sure.filter { !$0.right }.count,
                      asked: scored.filter(\.wasAsked).count, askedContainsRight: scored.filter(\.askedContainsRight).count,
                      riskyExpected: scored.filter(\.expectsRisky).count, riskyMissed: scored.filter(\.missedRisky).count,
                      calls: rows.reduce(0) { $0 + $1.calls },
                      decideMs: measureSpread(decided.map(\.row.decideMs)),
                      jevMs: measureSpread(decided.filter { $0.row.calls > 0 }.map(\.row.jevMs)),
                      rerankMs: measureSpread(decided.map(\.rerankMs).filter { $0 > 0 }),
                      projectedEndToActionMs: measureSpread(decided.map { projectEndToActionMs(decideMs: $0.row.decideMs) }),
                      tasks: TaskStats(cases: tasks.count, done: tasks.filter(\.finishedTask).count),
                      rows: rows)
    }

    // speculation starts Jev at speculateAfter, but nothing acts before the endpoint pause has confirmed the text
    private static func projectEndToActionMs(decideMs: Int) -> Int {
        let seconds = max(JayListener.endpointPause, JayListener.speculateAfter + Double(decideMs) / millisecondsPerSecond)
        return Int((seconds * millisecondsPerSecond).rounded())
    }

    private static func measureSpread(_ values: [Int]) -> Spread {
        Spread(p50: percentile(values, medianFraction), p90: percentile(values, tailFraction))
    }

    private static func summarize(_ report: Report) -> String {
        let taskRate = report.tasks.cases == 0 ? nil : Double(report.tasks.done) / Double(report.tasks.cases)
        let targetsMet = report.accuracy >= accuracyTarget && report.projectedEndToActionMs.p90 <= projectedTailTargetMs
            && report.riskyMissed == 0 && (taskRate ?? 1) >= taskDoneTarget
        return "jay-eval cases=\(report.cases) accuracy=\(String(format: "%.3f", report.accuracy)) (target >= \(accuracyTarget))"
            + " sure=\(report.sure) sureWrong=\(report.sureWrong) asked=\(report.asked) askedContainsRight=\(report.askedContainsRight)"
            + " calls=\(report.calls) decideP50=\(report.decideMs.p50)ms jevP50=\(report.jevMs.p50)ms"
            + " projectedP90=\(report.projectedEndToActionMs.p90)ms (target <= \(projectedTailTargetMs)ms)"
            + " riskyMissed=\(report.riskyMissed)/\(report.riskyExpected) (target 0)"
            + " tasks=\(report.tasks.done)/\(report.tasks.cases) (target >= \(taskDoneTarget)) targetsMet=\(targetsMet)"
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * millisecondsPerSecond).rounded())
    }

    // Typing reached as dictation types the same words into the same place as the expected `do`, and a
    // chained command's first step is the first action of the task it was expected to be.
    static func isRight(_ decision: JayDecision, expect: JayEvalCase.Expect, isChained: Bool = false) -> Bool {
        let isTyping = if case .type? = decision.action { true } else { false }
        let isSameTyping = expect.intent == .act && decision.intent == .dictate && isTyping
        let isChainedTask = isChained && expect.intent == .task && decision.intent == .act
        guard decision.intent == expect.intent || isSameTyping || isChainedTask else { return false }
        guard expect.actions.isEmpty || decision.action.map({ expect.actions.contains($0.key) }) == true else { return false }
        guard let text = expect.text else { return true }
        guard case .type(let typed, into: _)? = decision.action else { return false }
        return JayDecide.normalized(typed) == JayDecide.normalized(text)
    }

    static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func loadSnapshot(_ data: Data) throws -> ScreenSnapshot {
        let decoder = JSONDecoder()
        if let dump = try? decoder.decode(ScreenDump.self, from: data) { return dump.snapshot }
        return try decoder.decode(ScreenSnapshot.self, from: data)
    }
}
