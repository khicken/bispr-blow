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
        // Stacked fillers: the per-filler pass eats the space it matched on, so "uh uh" kept its
        // second "uh" until the repeated-word collapse moved ahead of it.
        precondition(LLMCleaner.ruleClean("um um so uh uh we should just ship it")
                     == "So we should just ship it")

        // Fillers the model left in its own output. Reported live: "like" and "uh" reaching the
        // cursor, from a reply the truncation guard accepted, so cleanup ran and simply missed them.
        precondition(LLMCleaner.stripFillers("It was, like, really slow.") == "It was really slow.")
        precondition(LLMCleaner.stripFillers("Too high. Like, way too high.") == "Too high. Way too high.")
        precondition(LLMCleaner.stripFillers("It ships Friday, you know.") == "It ships Friday.")
        // ...and the same words in their real senses are never touched. Losing one of these is
        // worse than leaving every filler in.
        precondition(LLMCleaner.stripFillers("I like it, and it looks like a bug, something like that.")
                     == "I like it, and it looks like a bug, something like that.")
        precondition(LLMCleaner.stripFillers("Do you know the answer?") == "Do you know the answer?")
        precondition(LLMCleaner.stripFillers("Ship it and like the post.") == "Ship it and like the post.")
        // Bare "like" mid-sentence is deliberately left in. "or like the task bar" is filler and
        // "and like the post" is a verb, and only what sits before the conjunction tells them
        // apart, so this one goes to the prompt rather than to a regex.
        precondition(LLMCleaner.stripFillers("the system tray or like the task bar")
                     == "the system tray or like the task bar")

        precondition(LLMCleaner.sanitize("```\nhello\n```", fallback: "x") == "hello")
        precondition(LLMCleaner.sanitize("", fallback: "fallback") == "fallback")

        let settings = AppSettings.shared
        let before = settings.dictionary
        settings.addDictionaryWords(["  worktree ", "Kubernetes", "worktree", ""])
        precondition(settings.dictionary.filter { $0 == "worktree" }.count == 1)
        precondition(settings.dictionary.contains("Kubernetes"))
        settings.dictionary = before

        print("self-check passed")
    }
}
