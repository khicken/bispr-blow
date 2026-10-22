import AppKit
import ApplicationServices

// What a voice command can act on: the pressable and typeable things in the front app's window and
// menu bar as Accessibility exposes them, plus the other apps that are running. Read on demand,
// never kept: it is a snapshot of someone else's screen.
struct ScreenElement {
    enum Kind { case press, field, app, web }

    let label: String
    let kind: Kind
    let element: AXUIElement?
    let app: NSRunningApplication?
}

enum ScreenElements {
    // Enough for a busy window; past this the choice list is noise and Jev slows down.
    private static let windowLimit = 200
    private static let menuLimit = 60
    private static let nodeBudget = 4000
    // Notes once took 30s to walk; past this the command runs on what was read so far.
    private static let timeBudget: TimeInterval = 0.5
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    static func read(app: NSRunningApplication) -> [ScreenElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A busy app answers each query late, and thousands of late answers add up to seconds. The
        // timeout is process-wide, so it goes back to the default for dictation's own reads.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }
        // Chromium and Electron build their tree only for a client that asks for it this way.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var found: [ScreenElement] = []
        var budget = nodeBudget
        var deadline = Date().addingTimeInterval(timeBudget)
        if let window: AXUIElement = attribute(root, kAXFocusedWindowAttribute) {
            walk(window, into: &found, limit: windowLimit, budget: &budget, deadline: deadline)
        }
        // Menus get their own allowance, or a busy window leaves none.
        budget = nodeBudget
        deadline = Date().addingTimeInterval(timeBudget)
        var menu: [ScreenElement] = []
        // The first menu is Apple's: Restart, Shut Down and Log Out are never a voice command's to press.
        let menus = (attribute(root, kAXMenuBarAttribute) as AXUIElement?)
            .flatMap { attribute($0, kAXChildrenAttribute) as [AXUIElement]? } ?? []
        for item in menus.dropFirst() {
            walk(item, into: &menu, limit: menuLimit, budget: &budget, deadline: deadline)
        }
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != app && $0.localizedName != nil }
            .map { ScreenElement(label: "\($0.localizedName!) (switch to app)", kind: .app, element: nil, app: $0) }
        // Somewhere to go when the thing asked for is not on screen at all: "go to LinkedIn".
        let web = ScreenElement(label: "Open a website or search the web (web)", kind: .web, element: nil, app: nil)
        // Jev takes at most 255 choices; the other apps and the web stay in, since they work from anywhere.
        let room = max(0, VoiceCommand.maxChoices - others.count - 1)
        return uniquelyLabelled(Array((found + menu).prefix(room)) + others + [web])
    }

    private static func walk(_ node: AXUIElement, into found: inout [ScreenElement], limit: Int, budget: inout Int, deadline: Date) {
        guard budget > 0, found.count < limit, Date() < deadline else { return }
        budget -= 1
        let role: String = attribute(node, kAXRoleAttribute) ?? ""
        // Chromium marks the wrapper of every link and row pressable too, which listed each one twice.
        if role != "AXGroup", role != "AXMenuBarItem", let label = label(of: node, role: role) {
            if fieldRoles.contains(role), !isSecure(node) {
                found.append(ScreenElement(label: label, kind: .field, element: node, app: nil))
            } else if actions(of: node).contains(kAXPressAction as String) {
                found.append(ScreenElement(label: label, kind: .press, element: node, app: nil))
            }
        }
        // A collapsed menu's items are still in the tree, which is what makes the menu bar readable.
        for child in (attribute(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            walk(child, into: &found, limit: limit, budget: &budget, deadline: deadline)
        }
    }

    private static func label(of node: AXUIElement, role: String) -> String? {
        let named = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .lazy.compactMap { (attribute(node, $0) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let text = named ?? (fieldRoles.contains(role) ? nil : firstText(under: node, depth: 3))
        guard let text, !text.isEmpty else { return nil }
        let kind: String = attribute(node, kAXRoleDescriptionAttribute) ?? role
        return "\(String(text.prefix(60))) (\(kind))"
    }

    private static func firstText(under node: AXUIElement, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for child in (attribute(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (attribute(child, kAXRoleAttribute) as String?) == "AXStaticText",
               let value: String = attribute(child, kAXValueAttribute), !value.isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let text = firstText(under: child, depth: depth - 1) { return text }
        }
        return nil
    }

    private static func isSecure(_ node: AXUIElement) -> Bool {
        (attribute(node, kAXSubroleAttribute) as String?) == "AXSecureTextField"
    }

    private static func actions(of node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func attribute<T>(_ node: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // Jev's choices are keyed by label, so two "Close (button)"s would collapse into one. Checked
    // against every label taken, since a real element can already be called "Close (button) #2".
    private static func uniquelyLabelled(_ elements: [ScreenElement]) -> [ScreenElement] {
        var taken = Set<String>()
        return elements.map { element in
            var label = element.label, count = 1
            while !taken.insert(label).inserted {
                count += 1
                label = "\(element.label) #\(count)"
            }
            return ScreenElement(label: label, kind: element.kind, element: element.element, app: element.app)
        }
    }
}
