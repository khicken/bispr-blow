import AppKit
import Carbon.HIToolbox

// Inserts text into the focused field of the frontmost app via pasteboard + synthetic ⌘V,
// then restores the previous pasteboard contents.
enum TextInserter {
    // Returns false when synthetic events can't be posted (no Accessibility trust):
    // the text is left on the clipboard so the user can ⌘V manually.
    // `thenReturn` presses Return once the paste has landed — the "dictate and send" binding.
    @discardableResult
    static func insert(_ text: String, thenReturn: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }
        let saved = savedItems(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Hint clipboard managers to ignore this transient write.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // Let the pasteboard write commit before synthesizing the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            postCmdV()
            // Return goes after the paste, on its own delay: sending before the field has the
            // text submits an empty message.
            if thenReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { postKey(CGKeyCode(kVK_Return)) }
            }
            // Restore after the paste lands; slow Electron apps read the clipboard late.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return true
    }

    // Every type of every item, so a copied image, file or rich text survives the paste. Promised
    // and dynamic types are skipped: their provider is gone after the restore. Over the cap, only the
    // plain text is kept, since reading a type makes the source app render it now.
    private static func savedItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        let cap = 20_000_000
        var total = 0
        var items: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types where !type.rawValue.hasPrefix("dyn.")
                && !type.rawValue.contains("promise") {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= cap else {
                    guard let string = pasteboard.string(forType: .string) else { return [] }
                    let text = NSPasteboardItem()
                    text.setString(string, forType: .string)
                    return [text]
                }
                copy.setData(data, forType: type)
            }
            if !copy.types.isEmpty { items.append(copy) }
        }
        return items
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
