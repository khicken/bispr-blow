import Foundation

extension SelfCheck {
    static func checkJayEval() {
        precondition(JayEval.percentile([100, 200, 300, 400, 500], 0.5) == 300)
        precondition(JayEval.percentile([100, 200, 300, 400, 500], 0.9) == 500)
        precondition(JayEval.percentile([], 0.9) == 0)

        typealias Expect = JayEvalCase.Expect
        let scrollDown = JayAction.system(SystemAction.named("scrollDown")!)
        let expectScroll = Expect(intent: .act, actions: [scrollDown.key], text: nil, risky: nil, task: nil)
        precondition(JayEval.isRight(evalDecision(.act, scrollDown), expect: expectScroll))
        precondition(!JayEval.isRight(evalDecision(.act, .system(SystemAction.named("scrollUp")!)), expect: expectScroll))
        precondition(!JayEval.isRight(evalDecision(.task, scrollDown), expect: expectScroll))
        precondition(JayEval.isRight(evalDecision(.stop, nil), expect: Expect(intent: .stop, actions: [], text: nil, risky: nil, task: nil)))
        let expectHello = Expect(intent: .act, actions: [], text: "hello world", risky: nil, task: nil)
        precondition(JayEval.isRight(evalDecision(.act, .type("Hello world", into: nil)), expect: expectHello))
        precondition(!JayEval.isRight(evalDecision(.act, .type("goodbye world", into: nil)), expect: expectHello))
        precondition(!JayEval.isRight(evalDecision(.act, scrollDown), expect: expectHello))
        precondition(JayEval.isRight(evalDecision(.dictate, .type("hello world", into: nil)), expect: expectHello))
        precondition(!JayEval.isRight(evalDecision(.dictate, scrollDown), expect: expectScroll))
        let newTab = JayAction.system(SystemAction.named("newTab")!)
        let expectTask = Expect(intent: .task, actions: [newTab.key], text: nil, risky: nil, task: true)
        precondition(JayEval.isRight(evalDecision(.act, newTab), expect: expectTask, isChained: true))
        precondition(!JayEval.isRight(evalDecision(.act, newTab), expect: expectTask))

        // only a sure, unflagged pick runs without asking
        let quit = JayAction.system(SystemAction.named("quitApp")!)
        precondition(!JayEval.runsUnasked(evalDecision(.act, quit), command: "nuke the app data"))
        precondition(JayEval.runsUnasked(evalDecision(.act, scrollDown), command: "scroll down"))

        let caseJSON = """
            {"id": "slack-dms", "command": "go to my DMs", "snapshot": "screens/com.tinyspeck.slackmacgap.json",
             "expect": {"intent": "do", "actions": ["press:DMs (tab)"], "risky": false}}
            """
        let evalCase = try! JSONDecoder().decode(JayEvalCase.self, from: Data(caseJSON.utf8))
        precondition(evalCase.expect.intent == .act && evalCase.expect.actions == ["press:DMs (tab)"])
        precondition(evalCase.live == nil && evalCase.expect.text == nil && evalCase.expect.risky == false)

        let bareSnapshot = """
            {"bundleID": "com.apple.TextEdit", "appName": "TextEdit", "pid": 42, "windowTitle": "Untitled",
             "elements": [], "source": "accessibility", "readMs": 12, "takenAt": 0}
            """
        let dumped = "{\"trusted\": true, \"ms\": 12, \"snapshot\": \(bareSnapshot)}"
        precondition((try? JayEval.loadSnapshot(Data(bareSnapshot.utf8)))?.bundleID == "com.apple.TextEdit")
        precondition((try? JayEval.loadSnapshot(Data(dumped.utf8)))?.pid == 42)
        precondition((try? JayEval.loadSnapshot(Data("{}".utf8))) == nil)
    }

    private static func evalDecision(_ intent: JayIntent, _ action: JayAction?) -> JayDecision {
        JayDecision(intent: intent, action: action, runnerUp: nil, confidence: 1, isSure: true, shortlist: [],
                    text: nil, status: nil, stuckProbability: nil, timings: JayTimings())
    }
}
