import Foundation

extension SelfCheck {
    static func checkJayTask() {
        precondition(JayRecipes.key(bundleID: "com.x", windowTitle: "Inbox", phrase: "  Open the  Settings!") == "com.x|Inbox|open the settings")
        checkJayRecipesFile()
        checkJayRecipeScreenCheck()
        checkJayTaskProgress()
        checkJayTaskMoves()
    }

    // A recipe file that silently fails to load looks exactly like one that was never written.
    private static func checkJayRecipesFile() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("jay-recipes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let steps = [JayRecipeStep(.system, target: "newTab"), JayRecipeStep(.type, target: "", text: "hello")]
        let first = JayRecipe(key: "k0", steps: steps, lastUsed: Date(timeIntervalSince1970: 0))
        JayRecipes(fileURL: fileURL).save(first)
        precondition(JayRecipes(fileURL: fileURL).recipe(for: "k0") == first, "jay recipe did not survive the round trip")

        let store = JayRecipes(fileURL: fileURL)
        for index in 1...JayRecipes.maxRecipes {
            store.save(JayRecipe(key: "k\(index)", steps: steps, lastUsed: Date(timeIntervalSince1970: Double(index))))
        }
        let reloaded = JayRecipes(fileURL: fileURL)
        precondition(reloaded.recipe(for: "k0") == nil, "least recently used jay recipe was not evicted")
        precondition(reloaded.recipe(for: "k1") != nil && reloaded.recipe(for: "k\(JayRecipes.maxRecipes)") != nil)

        try! Data("not json".utf8).write(to: fileURL)
        precondition(JayRecipes(fileURL: fileURL).recipe(for: "k1") == nil)
    }

    private static func checkJayRecipeScreenCheck() {
        let send = ScreenElement(label: "Send (button)", kind: .press, role: "AXButton", detail: "button in the toolbar", context: "", shortcut: nil, frame: nil)
        let screen = ScreenSnapshot(bundleID: "com.x", appName: "X", pid: 1, windowTitle: "Inbox", url: nil, focused: nil, selected: nil, elements: [send], source: .accessibility, readMs: 0, takenAt: Date())
        let pressSend = JayRecipes.step(for: .press(send))
        precondition(pressSend == JayRecipeStep(.press, target: "Send (button)"))
        precondition(JayRecipes.action(for: pressSend, screen: screen, apps: [])?.key == JayAction.press(send).key)
        precondition(JayRecipes.action(for: JayRecipeStep(.press, target: "Archive (button)"), screen: screen, apps: []) == nil)

        let safari = InstalledApp(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        let openSafari = JayRecipes.step(for: .openApp(safari))
        precondition(JayRecipes.action(for: openSafari, screen: screen, apps: [safari])?.key == JayAction.openApp(safari).key)
        precondition(JayRecipes.action(for: openSafari, screen: screen, apps: []) == nil)
        precondition(JayRecipes.action(for: JayRecipeStep(.type, target: "", text: "hi"), screen: screen, apps: []) != nil)
    }

    private static func checkJayTaskProgress() {
        var unchanged = JayTask.Progress()
        for key in ["a", "b", "c"] { unchanged.record(group: key, outcome: .unchanged) }
        precondition(unchanged.isOverLimit)

        var recovered = JayTask.Progress()
        recovered.record(group: "a", outcome: .unchanged)
        recovered.record(group: "b", outcome: .unchanged)
        recovered.record(group: "c", outcome: .done)
        recovered.record(group: "d", outcome: .unchanged)
        precondition(!recovered.isOverLimit)

        var repeated = JayTask.Progress()
        repeated.record(group: "a", outcome: .done)
        repeated.record(group: "a", outcome: .done)
        precondition(repeated.excluded.contains("a"))

        // Center (menu item) ran twice in a row in TextEdit: one that changed nothing is withdrawn at once
        var noEffect = JayTask.Progress()
        noEffect.record(group: "center", outcome: .unchanged)
        precondition(noEffect.excluded == ["center"] && noEffect.isRepeat("center") && !noEffect.isRepeat("type"))
        var lastOnly = JayTask.Progress()
        lastOnly.record(group: "type", outcome: .done)
        precondition(lastOnly.isRepeat("type") && lastOnly.excluded.isEmpty)

        // the loop that opened eleven documents: two routes to ⌘N taking turns with Return
        let newWindow = JayAction.system(SystemAction.named("newWindow")!)
        let newMenuItem = JayAction.press(ScreenElement(label: "New (menu item)", kind: .press, role: "AXMenuItem", detail: "",
                                                        context: "", shortcut: "⌘N", frame: nil))
        precondition(newWindow.group == newMenuItem.group)
        var alternating = JayTask.Progress()
        for action in [newWindow, .system(SystemAction.named("enter")!), newMenuItem] { alternating.record(group: action.group, outcome: .done) }
        precondition(alternating.excluded == [newWindow.group])

        var busy = JayTask.Progress()
        for index in 0..<JayTask.maxActions { busy.record(group: "k\(index)", outcome: .done) }
        precondition(busy.isOverLimit)
    }

    private static func checkJayTaskMoves() {
        precondition(JayTask.nextMove(status: .done, stuckProbability: nil, hasRunnerUp: true) == .finish)
        precondition(JayTask.nextMove(status: .stuck, stuckProbability: 0.8, hasRunnerUp: true) == .giveUp)
        precondition(JayTask.nextMove(status: .stuck, stuckProbability: 0.4, hasRunnerUp: true) == .runnerUp)
        precondition(JayTask.nextMove(status: .stuck, stuckProbability: 0.4, hasRunnerUp: false) == .giveUp)
        precondition(JayTask.nextMove(status: .next, stuckProbability: nil, hasRunnerUp: false) == .act)
    }
}
