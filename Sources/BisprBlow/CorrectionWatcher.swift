import AppKit
import ApplicationServices

/// Learns the words BisprBlow gets wrong, from the user fixing them.
///
/// A name that comes back misheard is misheard every time until it is in the dictionary, and the
/// only cure was remembering to open the Dictionary page later, which nobody does. So after text
/// lands, the field it landed in is watched for a short while: if exactly one word of what was
/// inserted has changed, that is a correction, and the corrected spelling is worth keeping.
///
/// Deliberately not a keystroke tap. Reading every key the user presses in another app is a
/// keylogger's shape, and this needs only a before and an after.
@MainActor
enum CorrectionWatcher {
    /// How long a fix is still plausibly a fix. Past this the user has moved on and an edit is
    /// them rewriting their own prose.
    private static let window: TimeInterval = 15
    private static let interval: TimeInterval = 0.5

    private static var task: Task<Void, Never>?

    /// A correction the user made: what BisprBlow wrote, and what they replaced it with.
    struct Correction {
        let misheard: String
        let corrected: String
    }

    /// Watches the field the text just landed in. Replaces any watch already running — the last
    /// dictation is the one being corrected.
    static func watch(inserted: String, onCorrection: @escaping (Correction) -> Void) {
        task?.cancel()
        guard inserted.split(whereSeparator: \.isWhitespace).count >= 2,
              let (element, pid) = ContextDetector.focusedElement() else { return }

        task = Task { @MainActor in
            // The paste has to land before there is anything to compare against.
            try? await Task.sleep(for: .seconds(1))
            guard let planted = ContextDetector.focusedText(element: element) else { return }
            let deadline = Date().addingTimeInterval(window)

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(interval))
                // Following the user into another app would compare two unrelated fields.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let current = ContextDetector.focusedText(element: element)
                else { return }
                guard current != planted else { continue }
                guard let fix = substitution(from: planted, to: current),
                      inserted.localizedCaseInsensitiveContains(fix.misheard),
                      LLMCleaner.learnable(misheard: fix.misheard, corrected: fix.corrected)
                else { return }
                logLine("correction learned \(fix.misheard) -> \(fix.corrected)")
                onCorrection(fix)
                return
            }
        }
    }

    static func cancel() { task?.cancel(); task = nil }

    /// The one word that changed, or nil.
    ///
    /// Nil for everything else on purpose — two changed words, an insertion, a deletion, a reflowed
    /// paragraph. Those are the user writing, and there is no way to tell which half of a rewrite
    /// was a mishear. Guessing there is what puts a wrong entry in the dictionary, and a wrong entry
    /// respells words that were already right.
    nonisolated static func substitution(from before: String, to after: String) -> Correction? {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        guard old.count == new.count else { return nil }

        var difference: Int?
        for index in old.indices where old[index] != new[index] {
            guard difference == nil else { return nil }
            difference = index
        }
        guard let index = difference else { return nil }

        let misheard = old[index].trimmingCharacters(in: .punctuation)
        let corrected = new[index].trimmingCharacters(in: .punctuation)
        guard !misheard.isEmpty, !corrected.isEmpty else { return nil }
        return Correction(misheard: misheard, corrected: corrected)
    }
}

private extension CharacterSet {
    /// Punctuation the recognizer or the user may have left around a word; the word itself is what
    /// goes in the dictionary.
    static let punctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}")
}
