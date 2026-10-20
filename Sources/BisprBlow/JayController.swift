import AppKit

// Turns what the listener hears into actions on the app in front, one command at a time. What it shows
// goes through the host's toast; what it logs is counts and timings, never what was said or on screen.
@MainActor
final class JayController {
    private static let tickInterval: TimeInterval = 0.1
    // The always-on recognizer hands over its whole session on every partial; a fresh one keeps that short.
    private static let recycleWords = 300

    private struct Plan: Sendable {
        let screen: ScreenSnapshot
        let decision: JayDecision
        let decideMs: Int
    }

    private enum StepResult: String { case done, asked, stopped, ignored, refused, unchanged, failed }

    private struct Choice {
        let id: Int
        let eventID: UUID
        let actions: [JayAction]
        let command: String
        let screen: ScreenSnapshot
    }

    private struct Confirmation {
        let id: Int
        let title: String
        let isRisky: Bool
        let resume: CheckedContinuation<Bool, Never>
    }

    private weak var host: DictationController?
    private var listener = JayListener(requiresWake: true)
    // Bumped by Esc and "stop"; queued work checks it before each step, since cancelling the newest Task
    // does not reach the ones it is waiting behind.
    private(set) var epoch = 0
    private var ticker: Timer?
    private var queue: Task<Void, Never>?
    // Dictate mode's inserts, in the order they were said: a short one cleans faster than a long one before it.
    private var dictation: Task<Void, Never>?
    private var runningCommands = 0
    private var speculation: (text: String, task: Task<Plan?, Error>)?
    private var choice: Choice?
    private var confirmation: Confirmation?
    private var questionCount = 0
    private var speechStartedAt: TimeInterval = 0
    // Raindrop threads a session's commands together and hangs undo, stop and picks on the command they answer.
    private var conversationID = UUID()
    private var commandEventID = UUID()
    private var lastCommandEventID: UUID?
    // The running task's steps, as they are reported, for the command's trace.
    private var taskSteps: [(title: String, at: Date)] = []

    init(host: DictationController) { self.host = host }

    var isBusy: Bool { runningCommands > 0 || choice != nil || confirmation != nil }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func milliseconds(since start: TimeInterval) -> Int { Int((now - start) * 1000) }

    // MARK: - Listening

    func beginListening(requiresWake: Bool) {
        listener = JayListener(requiresWake: requiresWake)
        listener.isBusy = runningCommands > 0
        conversationID = UUID()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // Whatever was being said is cut off, so a decision started on it must not run later on a matching command.
    func endListening() {
        ticker?.invalidate()
        ticker = nil
        dropSpeculation()
    }

    func hear(_ sessionText: String) {
        guard ticker != nil else { return }
        let now = Self.now
        if AppSettings.shared.jaySpeaks, JayVoice.isSpeaking { listener.ignoreUntil(now + JayListener.echoGuard) }
        handle(listener.hear(sessionText, at: now))
    }

    // The hotkey was let go: whatever it heard is a command, pause or no pause. The speculation stays for it.
    func finishListening(heard sessionText: String) {
        hear(sessionText)
        handle(listener.flush())
        ticker?.invalidate()
        ticker = nil
    }

    // Esc, "stop", or the user starting over: nothing heard or queued so far runs.
    func stop() {
        if isBusy, let last = lastCommandEventID { Raindrop.signal("stopped", on: last, isNegative: true) }
        epoch += 1
        dropSpeculation()
        listener.mode = .command
        queue?.cancel()
        resolveConfirmation(false)
        choice = nil
        JayLabels.hide()
    }

    private func tick() {
        handle(listener.tick(at: Self.now))
        guard listener.requiresWake, !listener.hasUtterance, runningCommands == 0, listener.sessionWords >= Self.recycleWords
        else { return }
        listener.restartSession()
        host?.recycleJaySession()
    }

    private func handle(_ event: JayListener.Event) {
        switch event {
        case .none:
            return
        case .speechStarted:
            speechStartedAt = Self.now
            ScreenWatcher.shared.prefetch()
        case .wake:
            speechStartedAt = Self.now
            ScreenWatcher.shared.prefetch()
            // An open question's notice carries its Do it button; "Listening" must not cover it.
            if choice == nil, confirmation == nil { host?.showNotice("Listening") }
        case .speculate(let text):
            speculate(text)
        case .commit(let text):
            commit(text)
        case .stopNow:
            stop()
            host?.showNotice("Stopped")
        case .sleep:
            stop()
            host?.sleepJay()
        case .switchMode(let mode):
            guard listener.mode == mode else {
                host?.showNotice("Dictate mode works while you hold the Voice command shortcut")
                return
            }
            host?.showNotice(mode == .dictate ? "Dictating. Say “command mode” to stop" : "Listening for commands")
        }
    }

    // Jev starts on the words heard so far; the decision is used only if the settled words are the same.
    private func speculate(_ heard: String) {
        // the same words `run` will decide on, or the speculation never matches its step
        let text = VoiceCommand.withoutLeadIn(heard)
        guard runningCommands == 0, choice == nil, confirmation == nil, VoiceCommand.steps(in: text).count == 1
        else { return }
        dropSpeculation()
        speculation = (text, Task { try await Self.makePlan(text) })
    }

    private func dropSpeculation() {
        speculation?.task.cancel()
        speculation = nil
    }

    private func commit(_ text: String) {
        if listener.mode == .dictate {
            let duration = max(0, Self.now - speechStartedAt - JayListener.dictatePause)
            let previous = dictation, context = ContextDetector.current()
            dictation = Task {
                await previous?.value
                await host?.insertDictation(raw: text, context: context, duration: duration)
            }
            return
        }
        if let pending = choice {
            choice = nil
            JayLabels.hide()
            if let number = JayListener.spokenNumber(text), pending.actions.indices.contains(number - 1) {
                let action = pending.actions[number - 1]
                enqueue { await self.runChosen(action, from: pending) }
                return
            }
            if JayListener.answer(text) == false { return }
        }
        if let pending = confirmation, let answer = JayListener.answer(text) {
            // Anyone in earshot can say "yes", call audio included, so always-on listening cannot approve a risky action.
            if answer, pending.isRisky, listener.requiresWake { return }
            resolveConfirmation(answer)
            return
        }
        resolveConfirmation(false)
        host?.showNotice("“\(text)”")
        let heardAt = listener.lastWordsAt
        enqueue { await self.run(text, heardAt: heardAt) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue, epoch = self.epoch
        runningCommands += 1
        listener.isBusy = true
        queue = Task {
            await previous?.value
            if epoch == self.epoch { await work() }
            runningCommands -= 1
            listener.isBusy = runningCommands > 0
        }
    }

    // MARK: - Acting

    private func run(_ text: String, heardAt: TimeInterval) async {
        let epoch = self.epoch
        var result = StepResult.done
        for (index, step) in VoiceCommand.steps(in: VoiceCommand.withoutLeadIn(text)).enumerated() {
            // The last step changed the screen; the app needs a beat to draw it before it is read again.
            if index > 0 { try? await Task.sleep(for: .seconds(JayTask.settleDelay)) }
            guard epoch == self.epoch else { return }
            result = await runStep(step, heardAt: heardAt, epoch: epoch)
            guard result == .done else { break }
        }
        guard epoch == self.epoch, result != .ignored else { return }
        listener.openFollowUp(at: Self.now)
    }

    private func runStep(_ step: String, heardAt: TimeInterval, epoch: Int) async -> StepResult {
        let stepStarted = Date()
        let speculated = takeSpeculation(matching: step)
        do {
            let made: Plan?
            if let speculated { made = try await speculated.value } else { made = try await Self.makePlan(step) }
            guard epoch == self.epoch else { return .stopped }
            guard let plan = made else {
                host?.showNotice("Couldn't read the app in front")
                return .failed
            }
            commandEventID = UUID()
            let eventID = commandEventID
            taskSteps = []
            let actStarted = Date()
            let result = await dispatch(plan, step: step, epoch: epoch)
            let actEnded = Date()
            let timings = plan.decision.timings, scores = plan.decision.scores
            Raindrop.trackCommand(eventID: eventID, conversationID: conversationID, said: step, did: Self.described(plan.decision, result),
                                  properties: ["app": plan.screen.appName, "intent": plan.decision.intent.rawValue, "outcome": result.rawValue,
                                               "confidence": plan.decision.confidence, "sure": plan.decision.isSure,
                                               "jev_calls": timings.calls, "decide_ms": plan.decideMs, "jev_ms": timings.jevMs,
                                               "heard_to_act_ms": Self.milliseconds(since: heardAt), "choices": plan.screen.elements.count,
                                               "speculative": speculated != nil, "screen_source": plan.screen.source.rawValue])
            if plan.decision.intent != .undo { lastCommandEventID = eventID }
            traceCommand(eventID: eventID, step: step, plan: plan, result: result, heardAt: Date(timeIntervalSinceNow: -(Self.now - heardAt)),
                         stepStarted: stepStarted, actStarted: actStarted, actEnded: actEnded)
            let rerank = scores.rerankBest.map { String(format: "%.2f/%.2f", $0, scores.rerankNext ?? 0) } ?? "none"
            logLine("""
                jay heardToActMs=\(Self.milliseconds(since: heardAt)) decideMs=\(plan.decideMs) jevMs=\(timings.jevMs) \
                calls=\(timings.calls) choices=\(plan.screen.elements.count) sure=\(plan.decision.isSure) firstSure=\(timings.calls == 1) \
                intent=\(plan.decision.intent.rawValue) intentP=\(String(format: "%.2f", scores.intent)) \
                top=\(String(format: "%.2f", scores.top)) second=\(String(format: "%.2f", scores.second)) rerank=\(rerank) \
                words=\(step.split(separator: " ").count) source=\(plan.screen.source.rawValue) \
                speculative=\(speculated == nil ? "miss" : "hit") outcome=\(result.rawValue)
                """)
            return result
        } catch Jev.Failure.noKey {
            host?.showNotice("Voice commands need a TypeSafe key in your Keychain")
        } catch Jev.Failure.keyRejected {
            host?.showNotice("TypeSafe rejected the key in your Keychain")
        } catch {
            // Esc cancels the request in flight; that is the user stopping, not Jev failing.
            guard epoch == self.epoch else { return .stopped }
            logLine("jay failed error=\(error.localizedDescription)")
            host?.showNotice("Couldn't reach Jev")
        }
        return .failed
    }

    private func takeSpeculation(matching step: String) -> Task<Plan?, Error>? {
        defer { speculation = nil }
        guard let speculation, JayListener.isSameCommand(speculation.text, step) else {
            speculation?.task.cancel()
            return nil
        }
        return speculation.task
    }

    private static func makePlan(_ step: String) async throws -> Plan? {
        guard let screen = await ScreenWatcher.shared.snapshot() else { return nil }
        let apps = await Task.detached { InstalledApps.all() }.value
        let started = now
        let decision = try await JayDecide.decide(step, screen: screen, apps: apps)
        return Plan(screen: screen, decision: decision, decideMs: milliseconds(since: started))
    }

    private func dispatch(_ plan: Plan, step: String, epoch: Int) async -> StepResult {
        let decision = plan.decision
        switch decision.intent {
        case .stop:
            stop()
            return .stopped
        case .sleep:
            stop()
            host?.sleepJay()
            return .stopped
        case .undo:
            if let last = lastCommandEventID { Raindrop.signal("undone", on: last, isNegative: true) }
            guard JayExecutor.undoLast() else {
                host?.showNotice("Nothing to undo")
                return .failed
            }
            return .done
        case .ignore:
            listener.closeFollowUp()
            return .ignored
        case .task:
            // The decision was made on one app's screen; anywhere else it presses nothing sensible.
            guard Self.isInFront(plan.screen) else { return couldNotDo() }
            return await runTask(step, first: decision, epoch: epoch)
        case .act, .dictate:
            guard let action = decision.action, Self.isInFront(plan.screen) else { return couldNotDo() }
            guard decision.isSure else {
                return await ask(among: decision.shortlist.isEmpty ? [action] : decision.shortlist, command: step, screen: plan.screen, epoch: epoch)
            }
            host?.showNotice(action.title)
            var outcome: JayOutcome? = await JayExecutor.runWithFallback(decision, command: step, isWakeListening: listener.requiresWake, screen: plan.screen,
                                                                         isCurrent: { self.epoch == epoch })
            if outcome == .needsConfirmation {
                outcome = await confirmAndRun(action, command: step, screen: plan.screen, epoch: epoch)
            }
            guard epoch == self.epoch else { return .stopped }
            return stepResult(of: outcome)
        }
    }

    private func runTask(_ goal: String, first: JayDecision, epoch: Int) async -> StepResult {
        let apps = await Task.detached { InstalledApps.all() }.value
        let task = await JayTask.run(goal: goal, first: first, apps: apps,
                                     isCurrent: { [weak self] in self?.epoch == epoch },
                                     report: { [weak self] in
                                         self?.taskSteps.append(($0, Date()))
                                         self?.host?.showNotice($0)
                                     },
                                     confirm: { [weak self] in await self?.askConfirmation(title: $0.title, isRisky: true) ?? false })
        logLine("jay task outcome=\(task.outcome.rawValue) actions=\(task.actions) replayed=\(task.replayed)")
        switch task.outcome {
        case .done: return .done
        case .stopped: return .stopped
        case .stuck, .limit, .failed:
            host?.showNotice("Couldn't finish that")
            speak("Couldn't finish that")
            return .failed
        }
    }

    // A shortlist of one is a yes/no question; more get numbered badges on screen and a spoken number.
    private func ask(among actions: [JayAction], command: String, screen: ScreenSnapshot, epoch: Int) async -> StepResult {
        guard actions.count > 1 else {
            return stepResult(of: await confirmAndRun(actions[0], command: command, screen: screen, epoch: epoch))
        }
        let shown = Array(actions.prefix(JayDecide.rerankSize))
        questionCount += 1
        let id = questionCount
        choice = Choice(id: id, eventID: commandEventID, actions: shown, command: command, screen: screen)
        JayLabels.show(shown.map(Self.frame(of:)))
        let options = shown.enumerated().map { "\($0.offset + 1) \($0.element.title)" }.joined(separator: " · ")
        host?.showNotice("Which one? \(options)", for: JayListener.followUpWindow)
        speak("Which one?")
        listener.openFollowUp(at: Self.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + JayListener.followUpWindow) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.choice?.id == id else { return }
                self.choice = nil
                JayLabels.hide()
            }
        }
        return .asked
    }

    private func runChosen(_ action: JayAction, from pending: Choice) async {
        Raindrop.signal("picked from question", on: pending.eventID, isNegative: false,
                        properties: ["picked": action.title, "rank": pending.actions.firstIndex { $0.title == action.title }.map { $0 + 1 } ?? 0])
        guard Self.isInFront(pending.screen) else {
            couldNotDo()
            return
        }
        let epoch = self.epoch
        var outcome: JayOutcome? = await JayExecutor.run(action, command: pending.command, isWakeListening: listener.requiresWake, screen: pending.screen, confirmed: false)
        if outcome == .needsConfirmation {
            outcome = await confirmAndRun(action, command: pending.command, screen: pending.screen, epoch: epoch)
        }
        guard epoch == self.epoch else { return }
        _ = stepResult(of: outcome)
        listener.openFollowUp(at: Self.now)
    }

    // nil when the user said no, let it time out, or moved on to another app or command.
    private func confirmAndRun(_ action: JayAction, command: String, screen: ScreenSnapshot, epoch: Int) async -> JayOutcome? {
        guard await askConfirmation(title: action.title, isRisky: JayExecutor.isRisky(action, command: command, isWakeListening: listener.requiresWake)),
              epoch == self.epoch, Self.isInFront(screen)
        else { return nil }
        return await JayExecutor.run(action, command: command, isWakeListening: listener.requiresWake, screen: screen, confirmed: true)
    }

    private func askConfirmation(title: String, isRisky: Bool) async -> Bool {
        resolveConfirmation(false)
        questionCount += 1
        let id = questionCount
        let prompt = isRisky && listener.requiresWake ? "Tap Do it" : "Say yes or tap Do it"
        host?.showNotice("\(title)? \(prompt)", for: JayListener.followUpWindow,
                         action: ("Do it", { [weak self] in self?.resolveConfirmation(true) }))
        speak("\(title)?")
        listener.openFollowUp(at: Self.now)
        DispatchQueue.main.asyncAfter(deadline: .now() + JayListener.followUpWindow) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.confirmation?.id == id else { return }
                self.resolveConfirmation(false)
            }
        }
        return await withCheckedContinuation { confirmation = Confirmation(id: id, title: title, isRisky: isRisky, resume: $0) }
    }

    private func resolveConfirmation(_ answer: Bool) {
        guard let pending = confirmation else { return }
        confirmation = nil
        host?.showNotice(answer ? pending.title : "Not done")
        pending.resume.resume(returning: answer)
    }

    private func stepResult(of outcome: JayOutcome?) -> StepResult {
        switch outcome {
        case .done?: return .done
        case nil, .needsConfirmation?: return .refused
        case .unchanged?:
            couldNotDo()
            return .unchanged
        case .failed?: return couldNotDo()
        }
    }

    // Each span is laid out from a measured duration ending where the next stage began, so the timeline is
    // the real one: heard, decided (build, Jev, the narrowed second look), acted, and a task's own steps.
    private func traceCommand(eventID: UUID, step: String, plan: Plan, result: StepResult, heardAt: Date,
                              stepStarted: Date, actStarted: Date, actEnded: Date) {
        typealias Span = Raindrop.Span
        let timings = plan.decision.timings
        let commandStart = min(heardAt, stepStarted)
        let decideStart = actStarted.addingTimeInterval(-Double(plan.decideMs) / 1000)
        let seconds = { (ms: Int) in Double(ms) / 1000 }
        let built = decideStart.addingTimeInterval(seconds(timings.buildMs))
        let firstCall = built.addingTimeInterval(seconds(timings.jevMs))
        var steps = [
            Span(name: "end of speech", kind: "task", start: min(heardAt, stepStarted), end: stepStarted),
            Self.readSpan(plan.screen, commandStart: commandStart),
            Span(name: "build choices", kind: "tool", start: decideStart, end: built),
        ]
        if timings.calls > 0 {
            steps.append(Span(name: "jev decide", kind: "tool", start: built, end: firstCall, input: step,
                              output: timings.calls > 1 ? "unsure, asked again" : Self.described(plan.decision, result)))
        }
        if timings.calls > 1 {
            steps.append(Span(name: "jev second look", kind: "tool", start: firstCall, end: firstCall.addingTimeInterval(seconds(timings.rerankMs)),
                              input: step, output: "confidence \(plan.decision.confidence)"))
        }
        let actIndex = steps.count
        steps.append(Span(name: plan.decision.intent == .task ? "run task" : "act", kind: "tool", start: actStarted, end: actEnded,
                          input: plan.decision.action?.title, output: result.rawValue))
        for (index, taskStep) in taskSteps.enumerated() {
            let end = index + 1 < taskSteps.count ? taskSteps[index + 1].at : actEnded
            steps.append(Span(name: taskStep.title, kind: "tool", start: taskStep.at, end: end, parent: actIndex))
        }
        Raindrop.trackTrace(eventID: eventID,
                            command: Span(name: "jay command", kind: "workflow", start: commandStart, end: actEnded,
                                          input: step, output: Self.described(plan.decision, result)),
                            steps: steps)
    }

    // The screen is read ahead of time and kept warm, so a read from before the command shows as a zero-length
    // mark with its age instead of stretching the command's timeline back to when it happened.
    private static func readSpan(_ screen: ScreenSnapshot, commandStart: Date) -> Raindrop.Span {
        let found = "\(screen.elements.count) choices via \(screen.source.rawValue)"
        let age = Int(commandStart.timeIntervalSince(screen.takenAt) * 1000)
        guard age > 0 else {
            return Raindrop.Span(name: "read screen", kind: "tool", start: screen.takenAt,
                                 end: screen.takenAt.addingTimeInterval(Double(screen.readMs) / 1000), input: screen.appName, output: found)
        }
        return Raindrop.Span(name: "read screen (prefetched)", kind: "tool", start: commandStart, end: commandStart, input: screen.appName,
                             output: "\(found), read in \(screen.readMs)ms, \(age)ms before the command")
    }

    // What Jay did, in words, for Raindrop's output column.
    private static func described(_ decision: JayDecision, _ result: StepResult) -> String {
        let target = decision.action?.title ?? decision.intent.rawValue
        switch result {
        case .done: return decision.intent == .task ? "Did the task, starting with \(target)" : "Did: \(target)"
        case .asked: return "Asked which one: " + (decision.shortlist.isEmpty ? [target] : decision.shortlist.map(\.title)).joined(separator: " · ")
        case .stopped: return "Stopped"
        case .ignored: return "Ignored (not for Jay)"
        case .refused: return "Refused: \(target)"
        case .unchanged: return "Tried \(target), nothing changed"
        case .failed: return "Couldn't do: \(target)"
        }
    }

    @discardableResult
    private func couldNotDo() -> StepResult {
        host?.showNotice("Couldn't do that")
        speak("Couldn't do that")
        return .failed
    }

    private func speak(_ phrase: String) {
        guard AppSettings.shared.jaySpeaks else { return }
        listener.ignoreUntil(Self.now + JayVoice.say(phrase) + JayListener.echoGuard)
    }

    private static func isInFront(_ screen: ScreenSnapshot) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == screen.pid
    }

    private static func frame(of action: JayAction) -> CGRect? {
        switch action {
        case .press(let element): return element.frame
        case .type(_, let field): return field?.frame
        case .system, .openApp, .openURL: return nil
        }
    }
}
