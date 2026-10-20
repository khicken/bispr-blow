import Foundation

extension SelfCheck {
    static func checkJayListen() {
        precondition(JayListener.command(afterWakeIn: "hey jay, open slack") == "open slack")
        precondition(JayListener.command(afterWakeIn: "Jay") == "")
        precondition(JayListener.command(afterWakeIn: "I told Jay about it") == nil, "a wake phrase mid-sentence is someone talking")
        checkJayEndpointing()
        checkJayFollowUp()
        checkJayPhrases()
    }

    private static func checkJayEndpointing() {
        var woken = JayListener(requiresWake: true)
        precondition(woken.hear("hey jay open slack", at: 0) == .wake)
        precondition(woken.tick(at: JayListener.speculateAfter) == .speculate("open slack"))
        precondition(woken.tick(at: JayListener.endpointPause) == .commit("open slack"))

        // "open Slack and" … "go to DMs" is one command with a breath in it.
        var dangling = JayListener(requiresWake: false)
        _ = dangling.hear("open slack and", at: 0)
        precondition(dangling.tick(at: JayListener.endpointPause) == .none, "a dangling word must hold the command open")
        precondition(dangling.tick(at: JayListener.danglingHoldMax) == .commit("open slack and"))

        var echo = JayListener(requiresWake: false)
        echo.ignoreUntil(1)
        precondition(echo.hear("done", at: 0.5) == .none, "Jay must not hear its own spoken reply")
        precondition(echo.tick(at: 2) == .none)
        _ = echo.hear("done scroll down", at: 2)
        precondition(echo.tick(at: 3) == .commit("scroll down"))

        var busy = JayListener(requiresWake: true)
        busy.isBusy = true
        precondition(busy.hear("stop", at: 0) == .stopNow, "stop must not wait for a wake phrase or a pause")

        var switching = JayListener(requiresWake: false)
        _ = switching.hear("dictate mode", at: 0)
        precondition(switching.tick(at: 1) == .switchMode(.dictate) && switching.mode == .dictate)

        var alwaysOn = JayListener(requiresWake: true)
        _ = alwaysOn.hear("jay dictate mode", at: 0)
        precondition(alwaysOn.tick(at: 1) == .switchMode(.dictate) && alwaysOn.mode == .command,
                     "always-on listening must never paste what the room says")
        precondition(alwaysOn.sessionWords == 3)
    }

    private static func checkJayFollowUp() {
        var listener = JayListener(requiresWake: true)
        _ = listener.hear("hey jay open slack", at: 0)
        precondition(listener.tick(at: 1) == .commit("open slack"))
        listener.openFollowUp(at: 1)
        _ = listener.hear("hey jay open slack scroll down", at: 2)
        precondition(listener.tick(at: 3) == .commit("scroll down"), "inside the follow-up window no wake phrase is needed")
        listener.openFollowUp(at: 3)
        let afterWindow = 3 + JayListener.followUpWindow + 1
        _ = listener.hear("hey jay open slack scroll down page down", at: afterWindow)
        precondition(listener.tick(at: afterWindow + 1) == .none, "after the follow-up window side talk must be ignored")
    }

    private static func checkJayPhrases() {
        precondition(JayListener.spokenNumber("two") == 2)
        precondition(JayListener.spokenNumber("number 3") == 3)
        precondition(JayListener.spokenNumber("the first one") == 1)
        precondition(JayListener.spokenNumber("fifteen") == nil)
        precondition(JayListener.answer("do it") == true)
        precondition(JayListener.answer("no") == false)
        precondition(JayListener.answer("maybe") == nil)
        precondition(JayListener.modeSwitch("dictate mode") == .switchMode(.dictate))
        precondition(JayListener.modeSwitch("jay sleep") == .sleep)
        precondition(JayListener.modeSwitch("Go to sleep.") == .sleep)
        precondition(JayListener.isSameCommand("Open Slack.", "open slack"))
    }
}
