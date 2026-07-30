import Carbon.HIToolbox
import CoreGraphics

/// One bindable trigger: a key (with optional modifiers) or a mouse button.
///
/// A standalone modifier key — fn, right ⌘ — is stored as `.key` with no modifier flags and
/// matched on its keycode alone, whatever else is held down. That is exactly what the fn-only
/// monitor always did, and it is what makes "hold fn" work while typing.
struct Shortcut: Codable, Equatable, Identifiable {
    enum Trigger: Codable, Equatable {
        /// Virtual keycode (`kVK_*`).
        case key(Int)
        /// CGEvent button number: 2 = middle, so 2 and up. Left and right stay the user's.
        case mouse(Int)
    }

    var trigger: Trigger
    /// `CGEventFlags` raw value, already narrowed to `tracked`.
    var flags: UInt64 = 0

    var id: String { display }

    static let fn = Shortcut(trigger: .key(kVK_Function))
    static let escape = Shortcut(trigger: .key(kVK_Escape))

    /// The modifier bits worth comparing. Everything else an event carries (numpad,
    /// non-coalesced, caps lock) is noise that would break an otherwise exact match.
    static let tracked: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ]

    /// Modifier keys that can stand alone as a trigger, and the flag each one raises.
    static let modifierFlags: [Int: CGEventFlags] = [
        kVK_Function: .maskSecondaryFn,
        kVK_Shift: .maskShift, kVK_RightShift: .maskShift,
        kVK_Control: .maskControl, kVK_RightControl: .maskControl,
        kVK_Option: .maskAlternate, kVK_RightOption: .maskAlternate,
        kVK_Command: .maskCommand, kVK_RightCommand: .maskCommand,
    ]

    // MARK: - Matching

    func matches(keyCode: Int, flags eventFlags: CGEventFlags) -> Bool {
        guard case .key(let code) = trigger, code == keyCode else { return false }
        if Self.modifierFlags[code] != nil { return true }  // standalone modifier: keycode is enough
        return eventFlags.intersection(Self.tracked).rawValue == flags
    }

    func matches(mouseButton: Int) -> Bool {
        if case .mouse(let button) = trigger { return button == mouseButton }
        return false
    }

    /// True when this binding needs the fn key, so the macOS Globe action has to be suppressed.
    var usesFn: Bool {
        if case .key(kVK_Function) = trigger { return true }
        return CGEventFlags(rawValue: flags).contains(.maskSecondaryFn)
    }

    // MARK: - Display

    /// Key-cap text: "fn", "⌃⌥D", "Mouse 4".
    var display: String {
        switch trigger {
        case .mouse(let button):
            return "Mouse \(button + 1)"  // 0 is left, so button 2 is what everyone calls mouse 3
        case .key(let code):
            if let name = Self.modifierNames[code] { return name }
            return Self.glyphs(for: CGEventFlags(rawValue: flags)) + (Self.keyNames[code] ?? "Key \(code)")
        }
    }

    /// Apple's order: fn, then ⌃⌥⇧⌘.
    private static func glyphs(for flags: CGEventFlags) -> String {
        var out = ""
        if flags.contains(.maskSecondaryFn) { out += "fn" }
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out
    }

    private static let modifierNames: [Int: String] = [
        kVK_Function: "fn",
        kVK_Shift: "⇧", kVK_RightShift: "Right ⇧",
        kVK_Control: "⌃", kVK_RightControl: "Right ⌃",
        kVK_Option: "⌥", kVK_RightOption: "Right ⌥",
        kVK_Command: "⌘", kVK_RightCommand: "Right ⌘",
    ]

    // ponytail: ANSI keycode table. On Dvorak or AZERTY the cap shows the US letter sitting at
    // that physical position; matching still works because it is keycode-based. Upgrade path is
    // UCKeyTranslate against the current keyboard layout.
    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
}

/// What a binding does. Every action takes a list of bindings, so ⌥Space and mouse 4 can both
/// start a dictation.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case handsFree
    case pressEnter
    case cancel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .handsFree: return "Hands-free"
        case .pressEnter: return "Dictate and send"
        case .cancel: return "Cancel"
        }
    }

    var blurb: String {
        switch self {
        case .pushToTalk: return "Hold to dictate, release to insert. Double-tap to go hands-free."
        // Says the double-tap out loud: hands-free ships with no binding of its own, and without
        // this the editor reads as though the feature were unavailable rather than already working.
        case .handsFree: return "Press once to start, again to finish. Double-tapping push to talk "
            + "does this too, so a binding here is only if you want a dedicated key."
        case .pressEnter: return "Like push to talk, but presses Return after the text lands."
        case .cancel: return "Throw away whatever is being dictated."
        }
    }

    /// Shipped defaults. fn stays push to talk and Esc stays cancel, so nobody's muscle
    /// memory breaks on upgrade.
    var defaults: [Shortcut] {
        switch self {
        case .pushToTalk: return [.fn]
        case .cancel: return [.escape]
        case .handsFree, .pressEnter: return []
        }
    }
}
