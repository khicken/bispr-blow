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

        print("self-check passed")
    }
}
