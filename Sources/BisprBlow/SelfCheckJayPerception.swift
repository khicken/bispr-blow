import CoreGraphics
import Foundation

extension SelfCheck {
    static func checkJayPerception() {
        precondition(ScreenElements.shortcutText(cmdChar: "S", modifiers: 0) == "⌘S")
        precondition(ScreenElements.shortcutText(cmdChar: "T", modifiers: 1) == "⇧⌘T")
        precondition(ScreenElements.shortcutText(cmdChar: "Q", modifiers: 4) == "⌃⌘Q")
        precondition(ScreenElements.shortcutText(cmdChar: "A", modifiers: 8) == "A")

        precondition(ScreenElements.detail(roleDescription: "button", place: "the toolbar", help: "Sends the message",
                                           shortcut: "⌘↩", states: ["selected"])
                     == "button in the toolbar. Sends the message. ⌘↩. selected")
        let longHelp = String(repeating: "word ", count: 100)
        precondition(ScreenElements.detail(roleDescription: "button", place: nil, help: longHelp, shortcut: nil, states: [])
            .count == ScreenElements.detailLimit)

        let close = ScreenElement(label: "Close (button)", kind: .press, role: "AXButton", detail: "", context: "",
                                  shortcut: nil, frame: nil)
        let realSecond = ScreenElement(label: "Close (button) #2", kind: .press, role: "AXButton", detail: "", context: "",
                                       shortcut: nil, frame: nil)
        let labels = ScreenElements.uniquelyLabelled([close, close, realSecond]).map(\.label)
        precondition(labels[0] == "Close (button)" && labels[1] == "Close (button) #2" && Set(labels).count == labels.count)

        var save = ScreenElement(label: "Save (menu item)", kind: .press, role: "AXMenuItem",
                                 detail: "menu item in the menu File. ⌘S", context: "File", shortcut: "⌘S",
                                 frame: CGRect(x: 10, y: 20, width: 30, height: 40))
        save.handle = .chrome(index: 3, generation: 1)
        let snapshot = ScreenSnapshot(bundleID: "com.x", appName: "X", pid: 1, windowTitle: "Inbox", url: nil, focused: nil,
                                      selected: nil, elements: [save], source: .accessibility, readMs: 5, takenAt: Date())
        let decoded = try! JSONDecoder().decode(ScreenSnapshot.self, from: try! JSONEncoder().encode(snapshot)).elements[0]
        precondition(decoded.label == save.label && decoded.detail == save.detail && decoded.kind == .press
                     && decoded.shortcut == "⌘S" && decoded.frame == save.frame && decoded.handle == nil && decoded.isMenuItem)

        let port = ChromeDevTools.activePort(fileContents: "9222\n/devtools/browser/abc")
        precondition(port?.port == 9222 && port?.path == "/devtools/browser/abc")
        precondition(ChromeDevTools.activePort(fileContents: "nope\n/devtools/browser/abc") == nil)
        precondition(ChromeDevTools.activePort(fileContents: "9222") == nil)

        let rows: [[String: Any]] = [
            ["name": "Sign in", "role": "button", "kind": "press", "place": "a form", "x": 10.0, "y": 20.0, "w": 30.0, "h": 40.0,
             "risk": "Sign in"],
            ["name": "Email", "role": "textbox", "kind": "field"],
            ["name": "", "role": "link", "kind": "press"],
        ]
        let web = ChromeDevTools.elements(fromCollected: rows, generation: 7, webAreaFrame: CGRect(x: 100, y: 200, width: 800, height: 600), scale: 2)
        precondition(web.count == 2)
        precondition(web[0].label == "Sign in (button)" && web[0].role == "web:button" && web[0].kind == .press)
        precondition(web[0].detail == "button in a form" && web[0].frame == CGRect(x: 120, y: 240, width: 60, height: 80) && web[0].riskText == "Sign in")
        precondition(web[1].label == "Email (text field)" && web[1].kind == .field && web[1].frame == nil)
        if case .chrome(let index, let generation) = web[1].handle { precondition(index == 1 && generation == 7) } else { preconditionFailure() }
    }
}
