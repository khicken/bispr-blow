import Foundation

struct JayTaskResult: Sendable {
    enum Outcome: String, Codable { case done, stopped, stuck, limit, failed }
    let outcome: Outcome
    let actions: Int
    let replayed: Bool
    let actionKeys: [String]
}

// A goal that takes several actions: Jev picks one action per screen until it says done. A recipe
// saved for the same phrase on the same window is replayed first.
@MainActor enum JayTask {
    nonisolated static let maxActions = 20
    nonisolated static let maxUnchanged = 3
    nonisolated static let repeatWindow = 2
    nonisolated static let stuckSureEnough = 0.5
    nonisolated static let settleDelay: TimeInterval = 0.3

    enum Move: Equatable { case act, runnerUp, finish, giveUp }

    struct Progress {
        private(set) var actions = 0, unchangedInARow = 0
        private(set) var recentGroups: [String] = []
        private(set) var excluded: Set<String> = []

        // a group picked again within the last two actions is withdrawn, so neither a loop on one button nor
        // two routes to one shortcut taking turns (New window, New menu item) can eat the action budget; one
        // that changed nothing is withdrawn at once, since pressing it again changes nothing either
        mutating func record(group: String, outcome: JayOutcome) {
            actions += 1
            if recentGroups.contains(group) || outcome != .done { excluded.insert(group) }
            recentGroups = Array((recentGroups + [group]).suffix(JayTask.repeatWindow))
            unchangedInARow = outcome == .done ? 0 : unchangedInARow + 1
        }

        func isRepeat(_ group: String) -> Bool { recentGroups.last == group || excluded.contains(group) }

        var isOverLimit: Bool { actions >= JayTask.maxActions || unchangedInARow >= JayTask.maxUnchanged }
    }

    static func run(goal: String, first: JayDecision?, apps: [InstalledApp], isCurrent: @escaping () -> Bool, report: @escaping (String) -> Void, confirm: @escaping (JayAction) async -> Bool) async -> JayTaskResult {
        let runner = Runner(goal: goal, apps: apps, isCurrent: isCurrent, report: report, confirm: confirm)
        guard isCurrent() else { return runner.result(.stopped) }
        guard let start = await ScreenWatcher.shared.snapshot() else { return runner.result(.failed) }
        let recipeKey = JayRecipes.key(bundleID: start.bundleID, windowTitle: start.windowTitle, phrase: goal)
        if let recipe = JayRecipes.shared.recipe(for: recipeKey), let replayOutcome = await runner.replay(recipe) {
            guard replayOutcome == .done else { return runner.result(replayOutcome) }
            JayRecipes.shared.save(JayRecipe(key: recipeKey, steps: recipe.steps, lastUsed: Date()))
            return runner.result(.done, replayed: true)
        }
        let outcome = await runner.loop(first: runner.progress.actions == 0 ? first : nil)
        if outcome == .done, !runner.steps.isEmpty {
            JayRecipes.shared.save(JayRecipe(key: recipeKey, steps: runner.steps, lastUsed: Date()))
        }
        return runner.result(outcome)
    }

    nonisolated static func nextMove(status: JayTaskStatus?, stuckProbability: Double?, hasRunnerUp: Bool) -> Move {
        switch status {
        case .done: return .finish
        case .stuck:
            guard hasRunnerUp, let stuckProbability, stuckProbability < stuckSureEnough else { return .giveUp }
            return .runnerUp
        case .next, nil: return .act
        }
    }

    @MainActor private final class Runner {
        let goal: String
        let apps: [InstalledApp]
        let isCurrent: () -> Bool
        let report: (String) -> Void
        let confirm: (JayAction) async -> Bool
        private(set) var progress = Progress()
        private(set) var titles: [String] = []
        private(set) var steps: [JayRecipeStep] = []
        private(set) var actionKeys: [String] = []
        private var typed: Set<String> = []

        init(goal: String, apps: [InstalledApp], isCurrent: @escaping () -> Bool, report: @escaping (String) -> Void, confirm: @escaping (JayAction) async -> Bool) {
            self.goal = goal
            self.apps = apps
            self.isCurrent = isCurrent
            self.report = report
            self.confirm = confirm
        }

        // nil means the replay was abandoned and the Jev loop carries on from the current screen
        func replay(_ recipe: JayRecipe) async -> JayTaskResult.Outcome? {
            for step in recipe.steps {
                guard isCurrent() else { return .stopped }
                guard let screen = await settledSnapshot(), let action = JayRecipes.action(for: step, screen: screen, apps: apps) else { return nil }
                guard let outcome = await act(action, on: screen) else { return .stopped }
                guard outcome == .done else { return nil }
            }
            return .done
        }

        func loop(first: JayDecision?) async -> JayTaskResult.Outcome {
            var pending = first?.isSure == true && first?.action != nil ? first : nil
            while !progress.isOverLimit {
                guard isCurrent() else { return .stopped }
                guard let screen = await settledSnapshot() else { return .failed }
                guard let decision = await nextDecision(pending, screen: screen) else { return isCurrent() ? .failed : .stopped }
                pending = nil
                let action: JayAction?
                switch JayTask.nextMove(status: decision.status, stuckProbability: decision.stuckProbability, hasRunnerUp: decision.runnerUp != nil) {
                case .finish: return .done
                case .giveUp: return .stuck
                case .act: action = decision.action
                case .runnerUp: action = decision.runnerUp
                }
                guard let action else { return .stuck }
                // the words are already in: picking them again means the goal's typing is done
                if case .type(let text, _) = action, typed.contains(text) { return .done }
                // a decision made before the withdrawal (the first one, or a runner-up) can still name it
                if progress.isRepeat(action.group) {
                    progress.record(group: action.group, outcome: .unchanged)
                    continue
                }
                guard await act(action, on: screen) != nil else { return .stopped }
            }
            return progress.unchangedInARow >= JayTask.maxUnchanged ? .stuck : .limit
        }

        func result(_ outcome: JayTaskResult.Outcome, replayed: Bool = false) -> JayTaskResult {
            logLine("jay task outcome=\(outcome.rawValue) actions=\(progress.actions) replayed=\(replayed)")
            return JayTaskResult(outcome: outcome, actions: progress.actions, replayed: replayed, actionKeys: actionKeys)
        }

        // nil when the user refused a risky step or the task was cancelled meanwhile
        private func act(_ action: JayAction, on screen: ScreenSnapshot) async -> JayOutcome? {
            guard isCurrent() else { return nil }
            report("Step \(progress.actions + 1): \(action.title)")
            // a goal is never the user naming Return, so a step's Return always asks
            var outcome = await JayExecutor.run(action, command: goal, isWakeListening: true, screen: screen, confirmed: false)
            if outcome == .needsConfirmation {
                guard await confirm(action), isCurrent() else { return nil }
                outcome = await JayExecutor.run(action, command: goal, isWakeListening: true, screen: screen, confirmed: true)
            }
            progress.record(group: action.group, outcome: outcome)
            actionKeys.append(action.key)
            if outcome == .done {
                titles.append(action.title)
                steps.append(JayRecipes.step(for: action))
                if case .type(let text, _) = action { typed.insert(text) }
            }
            return outcome
        }

        private func nextDecision(_ pending: JayDecision?, screen: ScreenSnapshot) async -> JayDecision? {
            if let pending { return pending }
            let context = JayTaskContext(goal: goal, done: titles, excludedGroups: progress.excluded)
            do {
                return try await JayDecide.decide(goal, screen: screen, apps: apps, task: context)
            } catch {
                if isCurrent() { logLine("jay task decide failed error=\(error)") }
                return nil
            }
        }

        // the last action changed the screen; the app needs a beat to draw it before it is read again
        private func settledSnapshot() async -> ScreenSnapshot? {
            if progress.actions > 0 { try? await Task.sleep(for: .seconds(JayTask.settleDelay)) }
            return await ScreenWatcher.shared.snapshot()
        }
    }
}
