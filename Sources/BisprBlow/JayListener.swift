import Foundation

// Cuts what the mic heard into commands: a wake phrase at the start of an utterance, a short pause to
// end it, and a follow-up window in which the next command needs no wake phrase. Times are
// `ProcessInfo.systemUptime` seconds, passed in so `--self-check` can drive it with a made-up clock.
struct JayListener {
    enum Mode: String { case command, dictate }
    enum Event: Equatable { case none, speechStarted, wake, speculate(String), commit(String), stopNow, sleep, switchMode(Mode) }

    static let endpointPause: TimeInterval = 0.35
    // Jev takes ~120ms, so a decision started here is ready by the time the pause has lasted endpointPause.
    static let speculateAfter: TimeInterval = 0.15
    static let danglingHoldMax: TimeInterval = 1.2
    static let dictatePause: TimeInterval = 0.8
    static let followUpWindow: TimeInterval = 8
    static let echoGuard: TimeInterval = 0.3
    static let wakeTerms = ["Jay", "Hey Jay"]

    var requiresWake: Bool
    var mode = Mode.command
    var isBusy = false
    private(set) var lastWordsAt: TimeInterval = 0
    // Counted in words, not characters: the recognizer respells words it already gave ("slak" → "Slack"),
    // which shifts characters but not words.
    private var consumedWords = 0
    private(set) var sessionWords = 0
    private var utterance = ""
    private var startedAt: TimeInterval = 0
    private var hasWoken = false
    private var hasSpeculated = false
    private var followUpUntil = -TimeInterval.infinity
    private var ignoredUntil = -TimeInterval.infinity

    init(requiresWake: Bool) { self.requiresWake = requiresWake }

    var hasUtterance: Bool { !utterance.isEmpty }

    private var needsWake: Bool { requiresWake && mode == .command && startedAt > followUpUntil }

    // The recognizer hands over the whole session each time, so only words past the consumed ones count.
    mutating func hear(_ sessionText: String, at time: TimeInterval) -> Event {
        let words = sessionText.split(whereSeparator: \.isWhitespace)
        sessionWords = words.count
        consumedWords = min(consumedWords, sessionWords)
        guard time >= ignoredUntil else {
            consume()
            return .none
        }
        let fresh = words.dropFirst(consumedWords).joined(separator: " ")
        guard !JayDecide.normalized(fresh).isEmpty, !Self.isSameCommand(fresh, utterance) else { return .none }
        let isFirstWords = utterance.isEmpty
        if isFirstWords { startedAt = time }
        utterance = fresh
        lastWordsAt = time
        hasSpeculated = false
        let woken = Self.command(afterWakeIn: fresh)
        if isBusy, JayDecide.localIntent(fresh) == .stop {
            consume()
            return .stopNow
        }
        if needsWake, !hasWoken, woken != nil {
            hasWoken = true
            return .wake
        }
        return isFirstWords && !needsWake ? .speechStarted : .none
    }

    mutating func tick(at time: TimeInterval) -> Event {
        guard hasUtterance else { return .none }
        let quiet = time - lastWordsAt
        if mode == .dictate {
            guard quiet >= Self.dictatePause else { return .none }
            let text = utterance
            consume()
            return Self.modeSwitch(text).map { applied($0, at: time) } ?? .commit(text)
        }
        let woken = Self.command(afterWakeIn: utterance)
        let command: String? = needsWake ? woken : woken ?? utterance
        guard let command else {
            if quiet >= Self.endpointPause { consume() }
            return .none
        }
        let isHeld = VoiceCommand.isUnfinished(command) && quiet < Self.danglingHoldMax
        if !isHeld, !hasSpeculated, !command.isEmpty, quiet >= Self.speculateAfter, quiet < Self.endpointPause {
            hasSpeculated = true
            return .speculate(command)
        }
        guard !isHeld, quiet >= Self.endpointPause else { return .none }
        consume()
        guard !command.isEmpty else {
            openFollowUp(at: time)
            return .none
        }
        return Self.modeSwitch(command).map { applied($0, at: time) } ?? .commit(command)
    }

    // Whatever is left when the hotkey is let go, pause or no pause.
    mutating func flush() -> Event {
        guard hasUtterance else { return .none }
        let command = Self.command(afterWakeIn: utterance) ?? utterance
        consume()
        return command.isEmpty ? .none : .commit(command)
    }

    mutating func openFollowUp(at time: TimeInterval) { followUpUntil = time + Self.followUpWindow }

    mutating func closeFollowUp() { followUpUntil = -TimeInterval.infinity }

    mutating func ignoreUntil(_ time: TimeInterval) { ignoredUntil = max(ignoredUntil, time) }

    // A fresh recognizer session starts its text from nothing.
    mutating func restartSession() {
        sessionWords = 0
        consume()
    }

    private mutating func consume() {
        consumedWords = sessionWords
        utterance = ""
        hasWoken = false
        hasSpeculated = false
    }

    // Always-on listening hears side talk and call audio, so it never pastes what it hears at the cursor:
    // dictate mode is for a shortcut session only.
    private mutating func applied(_ event: Event, at time: TimeInterval) -> Event {
        if case .switchMode(let next) = event, !requiresWake || next == .command {
            mode = next
            openFollowUp(at: time)
        }
        return event
    }

    // MARK: - Phrases

    private static let wakePrefix = try! NSRegularExpression(pattern: #"^\s*(?:hey[\s,]+)?jay\b[\s\p{P}]*"#, options: .caseInsensitive)
    private static let dictatePhrases: Set<String> = ["dictate mode", "dictation mode", "start dictating"]
    private static let commandPhrases: Set<String> = ["command mode", "stop dictating"]
    private static let yesPhrases: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it", "go ahead", "yes please", "yes do it"]
    private static let noPhrases: Set<String> = ["no", "nope", "cancel", "dont", "do not", "dont do it", "never mind"]
    private static let numberFillers: Set<String> = ["number", "the", "option", "choice", "pick", "press", "click", "select", "choose", "tap"]
    private static let numbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
    ]

    // Only a wake phrase that STARTS the utterance counts: "I told Jay about it" is someone talking.
    static func command(afterWakeIn utterance: String) -> String? {
        guard let match = wakePrefix.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)),
              let range = Range(match.range, in: utterance)
        else { return nil }
        return String(utterance[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func spokenNumber(_ text: String) -> Int? {
        var words = phrase(text).split(separator: " ").map(String.init).filter { !numberFillers.contains($0) }
        if words.count > 1, words.last == "one" { words.removeLast() }
        guard words.count == 1 else { return nil }
        return numbers[words[0]]
    }

    static func answer(_ text: String) -> Bool? {
        let said = phrase(text)
        if yesPhrases.contains(said) { return true }
        if noPhrases.contains(said) { return false }
        return nil
    }

    static func modeSwitch(_ text: String) -> Event? {
        let said = phrase(text)
        if dictatePhrases.contains(said) { return .switchMode(.dictate) }
        if commandPhrases.contains(said) { return .switchMode(.command) }
        if JayDecide.localIntent(text) == .sleep { return .sleep }
        return nil
    }

    static func isSameCommand(_ a: String, _ b: String) -> Bool { JayDecide.normalized(a) == JayDecide.normalized(b) }

    private static func phrase(_ text: String) -> String { JayDecide.normalized(command(afterWakeIn: text) ?? text) }
}
