import CoreGraphics
import Foundation

extension SelfCheck {
    // The ask-first gate, the change check and the coordinate flip are pure, and each one failing
    // silently means a send without asking, a second action on top of one that worked, or a badge
    // drawn over the wrong button.
    static func checkJayAct() {
        precondition(JayLabels.cocoaRect(fromAX: CGRect(x: 10, y: 20, width: 30, height: 40), primaryScreenHeight: 1000)
                     == CGRect(x: 10, y: 940, width: 30, height: 40))

        let inbox = ScreenFingerprint(bundleID: "com.apple.mail", windowTitle: "Inbox", windowCount: 1, focusedRole: "AXTextArea",
                                      focusedTitle: "", focusedValueLength: 0, url: nil, childCount: 12)
        precondition(!JayExecutor.didChange(inbox, inbox))
        precondition(JayExecutor.didChange(inbox, changedFingerprint(inbox, windowTitle: "Sent")))
        precondition(JayExecutor.didChange(inbox, changedFingerprint(inbox, focusedValueLength: 5)))

        let delete = ScreenElement(label: "Delete (button)", kind: .press, role: "AXButton", detail: "button in the toolbar",
                                   context: "", shortcut: nil, frame: nil)
        let enter = JayAction.system(SystemAction.named("enter")!)
        let scrollDown = JayAction.system(SystemAction.named("scrollDown")!)
        precondition(JayExecutor.isRisky(.press(delete), command: "press that one", isWakeListening: false))
        precondition(!JayExecutor.isRisky(enter, command: "press enter", isWakeListening: false), "Return the user asked for is theirs")
        precondition(!JayExecutor.isRisky(enter, command: "Hit return.", isWakeListening: false))
        precondition(JayExecutor.isRisky(enter, command: "tell bob I'm running late", isWakeListening: false), "Return picked for a goal can send it")
        precondition(JayExecutor.isRisky(enter, command: "press enter", isWakeListening: true), "a wake word can come from anyone in earshot")
        precondition(!JayExecutor.isRisky(scrollDown, command: "scroll down", isWakeListening: false))
        precondition(JayExecutor.isRisky(.system(SystemAction.named("quitApp")!), command: "nuke the app data", isWakeListening: false))
        precondition(!JayExecutor.isRisky(.type("hello", into: nil), command: "type hello", isWakeListening: false))
        precondition(JayExecutor.isRisky(scrollDown, command: "send it", isWakeListening: false))
        precondition(!JayExecutor.isRisky(.openURL(URL(string: "https://github.com")!), command: "go to github.com", isWakeListening: false))
        for label in ["Clear application data… (menu item)", "Close All Tabs (menu item)", "Kill Terminal (button)"] {
            let element = ScreenElement(label: label, kind: .press, role: "AXButton", detail: "", context: "", shortcut: nil, frame: nil)
            precondition(JayExecutor.isRisky(.press(element), command: "press it", isWakeListening: false), label)
        }
        let allClear = ScreenElement(label: "All Clear (button)", kind: .press, role: "AXButton", detail: "", context: "", shortcut: nil, frame: nil)
        precondition(!JayExecutor.isRisky(.press(allClear), command: "press it", isWakeListening: false))
        let disguised = ScreenElement(label: "Continue (button)", kind: .press, role: "web:button", detail: "", context: "", shortcut: nil,
                                      frame: nil, riskText: "Delete account Continue")
        precondition(JayExecutor.isRisky(.press(disguised), command: "press continue", isWakeListening: false), "a page's own label must not hide what it does")

        precondition(JayExecutor.mediaKeyData(16, isDown: true) == (16 << 16) | (0xA << 8))
    }

    private static func changedFingerprint(_ base: ScreenFingerprint, windowTitle: String? = nil, focusedValueLength: Int? = nil) -> ScreenFingerprint {
        ScreenFingerprint(bundleID: base.bundleID, windowTitle: windowTitle ?? base.windowTitle, windowCount: base.windowCount,
                          focusedRole: base.focusedRole, focusedTitle: base.focusedTitle,
                          focusedValueLength: focusedValueLength ?? base.focusedValueLength, url: base.url, childCount: base.childCount)
    }
}
