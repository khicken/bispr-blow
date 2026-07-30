import Foundation

/// `BluejayWispr --self-check`: asserts the text logic that silently loses user words if
/// it breaks. `precondition`, not `assert` — release builds strip asserts.
enum SelfCheck {
    static func run() {
        let raw = "okay so um i tested the new build and uh the login flow it's mostly working "
            + "but i found like two issues one is the spinner never goes away and two um when "
            + "you log out it doesn't clear the session so we should fix those before friday"

        // Trailing off, or coming back half-length, means content was dropped.
        precondition(LLMCleaner.looksTruncated("We should update the prompt and tailor...", raw: raw))
        precondition(LLMCleaner.looksTruncated("I tested the new build and found two issues.", raw: raw))
        // Elision mid-sentence, on a short dictation — "what's in this PR?" became "...".
        precondition(LLMCleaner.looksTruncated(
            "Yeah, wait... Can you see the link again?",
            raw: "Yeah, wait, what's in this PR? Can you see the link again?"))
        // An ellipsis the speaker actually dictated is not the model's doing.
        precondition(!LLMCleaner.looksTruncated("Wait... never mind.", raw: "wait ... never mind"))
        // A leaked reasoning trace, or the model answering instead of cleaning, runs long.
        precondition(LLMCleaner.looksTruncated(
            "Okay, let me tackle this. The user is dictating in Slack and wants the transcript "
            + "cleaned. First I should check for filler words, then apply the style rules for "
            + "chat, then make sure the question is preserved rather than answered.",
            raw: "yeah wait what's in this PR"))
        precondition(!LLMCleaner.looksTruncated(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw: raw))
        // Short dictations legitimately shrink a lot.
        precondition(!LLMCleaner.looksTruncated("Does it work?", raw: "um does it uh does it work"))

        precondition(LLMCleaner.ruleClean("um the the tests uh pass") == "The tests pass")
        precondition(LLMCleaner.sanitize("```\nhello\n```", fallback: "x") == "hello")
        precondition(LLMCleaner.sanitize("", fallback: "fallback") == "fallback")

        let settings = AppSettings.shared
        let before = settings.dictionary
        settings.addDictionaryWords(["  worktree ", "Kubernetes", "worktree", ""])
        precondition(settings.dictionary.filter { $0 == "worktree" }.count == 1)
        precondition(settings.dictionary.contains("Kubernetes"))
        settings.dictionary = before

        // A section left out of a sidebar group just disappears from the nav, silently.
        precondition(DashboardView.Section.groups.flatMap(\.items) == DashboardView.Section.allCases)

        // Dropping the pill snaps it to the nearest anchor. Snapping on x alone made a vertical
        // drag teleport back to the bottom, so both axes count.
        let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
        let pill = CGSize(width: 122, height: 48)
        typealias Anchor = RecordingPillController.Anchor
        // Dropped near the left edge halfway up: the left anchor, not the bottom one.
        precondition(Anchor.nearest(to: NSPoint(x: 60, y: 500), size: pill, in: screen) == .leftCentre)
        precondition(Anchor.nearest(to: NSPoint(x: 1300, y: 500), size: pill, in: screen) == .rightCentre)
        precondition(Anchor.nearest(to: NSPoint(x: 676, y: 30), size: pill, in: screen) == .bottomCentre)
        // Dropped low but hard left still belongs on the left edge.
        precondition(Anchor.nearest(to: NSPoint(x: 40, y: 300), size: pill, in: screen) == .leftCentre)
        precondition(Anchor.leftCentre.origin(size: pill, in: screen) == NSPoint(x: 12, y: 415))
        precondition(Anchor.rightCentre.origin(size: pill, in: screen) == NSPoint(x: 1218, y: 415))
        precondition(Anchor.bottomCentre.origin(size: pill, in: screen) == NSPoint(x: 615, y: 0))

        print("self-check passed")
    }
}
