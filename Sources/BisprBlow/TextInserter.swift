import AppKit
import Carbon.HIToolbox

// Inserts text into the focused field of the frontmost app via pasteboard + synthetic ⌘V,
// then restores the previous pasteboard contents.
@MainActor
enum TextInserter {
    // Let the pasteboard write commit before synthesizing the paste.
    private static let commitDelay: Duration = .milliseconds(100)
    // Return goes after the paste, on its own delay: sending before the field has the text submits an empty message.
    private static let returnDelay: Duration = .milliseconds(120)
    // Slow Electron apps read the clipboard late.
    private static let restoreDelay: Duration = .milliseconds(600)
    private static var lastPaste: Task<Void, Never>?

    // Returns false when synthetic events can't be posted (no Accessibility trust):
    // the text is left on the clipboard so the user can ⌘V manually.
    // `thenReturn` presses Return once the paste has landed — the "dictate and send" binding.
    @discardableResult
    static func insert(_ text: String, thenReturn: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return false
        }
        Task { await paste(text, thenReturn: thenReturn) }
        return true
    }

    // Back once the field has the text, so what comes next sees it; the clipboard restore carries on behind.
    static func insertAndWait(_ text: String) async -> Bool {
        guard AXIsProcessTrusted() else { return insert(text) }
        await paste(text, thenReturn: false)
        try? await Task.sleep(for: returnDelay)
        return true
    }

    // One paste at a time: two in flight each save the other's text as the user's clipboard. Returns once
    // ⌘V is posted; the next paste still waits for the restore.
    private static func paste(_ text: String, thenReturn: Bool) async {
        let previous = lastPaste
        let pasted = Task {
            await previous?.value
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Hint clipboard managers to ignore this transient write.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let ours = pasteboard.changeCount
            try? await Task.sleep(for: commitDelay)
            postCmdV()
            if thenReturn {
                try? await Task.sleep(for: returnDelay)
                postKey(CGKeyCode(kVK_Return))
            }
            return (saved, ours)
        }
        lastPaste = Task {
            let (saved, ours) = await pasted.value
            try? await Task.sleep(for: restoreDelay)
            let pasteboard = NSPasteboard.general
            // Something the user copied meanwhile is theirs to keep.
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        _ = await pasted.value
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else { return }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    private static func postKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(10_000)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
