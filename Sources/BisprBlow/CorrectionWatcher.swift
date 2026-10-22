import AppKit
import ApplicationServices

// Learns the words the app gets wrong, from the user fixing them. A misheard name stays misheard
// until it is in the dictionary, and the only cure was remembering to open the Dictionary page. So
// after text lands, the field it landed in is watched until the user sends it, clears it or moves
// on, and the last text seen is compared with what was inserted: one short stretch replaced is a
// correction worth keeping. Deliberately not a keystroke tap — reading every key the user presses in
// another app is a keylogger's shape, and this needs only a before and an after.
@MainActor
enum CorrectionWatcher {
    // A cap, not the usual end: a chat box clears on send, which settles the watch long before this.
    private static let window: TimeInterval = 120
    private static let interval: TimeInterval = 0.5

    private static var task: Task<Void, Never>?
    private static var pending: (element: AXUIElement, inserted: String, planted: String, lastSeen: String,
                                 onCorrection: (Correction) -> Void)?

    // A correction the user made: what BisprBlow wrote, and what they replaced it with. Up to
    // `longestFix` words on either side.
    struct Correction {
        let misheard: String
        let corrected: String
    }

    nonisolated static let longestFix = 3

    // Watches the field the text just landed in.
    static func watch(inserted: String, onCorrection: @escaping (Correction) -> Void) {
        cancel()
        guard inserted.split(whereSeparator: \.isWhitespace).count >= 2,
              let (element, pid) = ContextDetector.focusedElement() else { return }

        task = Task { @MainActor in
            // The paste has to land before there is anything to compare against.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let planted = ContextDetector.focusedText(element: element) else { return }
            pending = (element, inserted, planted, planted, onCorrection)
            let deadline = Date().addingTimeInterval(window)
            // Sent, cleared, or left for another app: the last text seen is what the user settled on.
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let current = ContextDetector.focusedText(element: element)
                else { break }
                pending?.lastSeen = current
            }
            if !Task.isCancelled { settle() }
        }
    }

    // Settles rather than drops: whatever the user fixed before this point is final.
    static func cancel() {
        settle()
        task?.cancel()
        task = nil
    }

    private static func settle() {
        guard let watch = pending else { return }
        pending = nil
        // Read once more: a fix made in the half second before the next shortcut is still a fix.
        let final = ContextDetector.focusedText(element: watch.element) ?? watch.lastSeen
        guard let fix = substitution(from: watch.planted, to: final),
              watch.inserted.localizedCaseInsensitiveContains(fix.misheard)
        else { return }
        watch.onCorrection(fix)
    }

    // The one stretch of up to `longestFix` words that changed, or nil. Nil for an insertion, a
    // deletion, two edits around a kept word, a reflowed paragraph: those are the user writing, and there is
    // no telling which half of a rewrite was a mishear. A wrong entry respells words that were
    // already right. Words compare without their punctuation, which belongs to the sentence.
    nonisolated static func substitution(from before: String, to after: String) -> Correction? {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        let same = { (a: String, b: String) in
            a.trimmingCharacters(in: .punctuation) == b.trimmingCharacters(in: .punctuation)
        }
        var start = 0
        while start < min(old.count, new.count), same(old[start], new[start]) { start += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, same(old[oldEnd - 1], new[newEnd - 1]) {
            oldEnd -= 1
            newEnd -= 1
        }
        guard (1...longestFix).contains(oldEnd - start), (1...longestFix).contains(newEnd - start),
              !old[start..<oldEnd].contains(where: { word in new[start..<newEnd].contains { same(word, $0) } })
        else { return nil }

        let misheard = old[start..<oldEnd].joined(separator: " ").trimmingCharacters(in: .punctuation)
        let corrected = new[start..<newEnd].joined(separator: " ").trimmingCharacters(in: .punctuation)
        guard !misheard.isEmpty, !corrected.isEmpty else { return nil }
        return Correction(misheard: misheard, corrected: corrected)
    }
}

private extension CharacterSet {
    // Punctuation the recognizer or the user may have left around a word; the word itself is what
    // goes in the dictionary.
    static let punctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}")
}
