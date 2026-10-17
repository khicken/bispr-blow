import AppKit
import ApplicationServices

// What a voice command can act on: the pressable and typeable things in the front app's window and
// menu bar as Accessibility exposes them. A snapshot of someone else's screen: never logged.
struct ScreenElement: Codable, @unchecked Sendable {
    enum Kind: String, Codable { case press, field }
    // A Chrome row is found again by which collection it came from, so a later read cannot repoint it.
    enum Handle { case ax(AXUIElement), chrome(index: Int, generation: Int) }

    // Unique within a snapshot, because it is Jev's criteria key: "Send (button)", "Send (button) #2".
    let label: String
    let kind: Kind
    // AX role ("AXButton", "AXMenuItem") or "web:<role>" for a row read over Chrome DevTools.
    let role: String
    let detail: String
    let context: String
    // Rendered exactly like `Shortcut.display`, so a menu item and a system action can be matched.
    let shortcut: String?
    // Global AX coordinates, top-left origin.
    let frame: CGRect?
    var handle: Handle? = nil
    // Every name the element goes by, visible text included, for the ask-first check only: a page can
    // label a "Delete account" button "Continue". Never sent to Jev.
    var riskText = ""

    var isMenuItem: Bool { role == "AXMenuItem" }

    private enum CodingKeys: String, CodingKey { case label, kind, role, detail, context, shortcut, frame }
}

struct ScreenSnapshot: Codable, @unchecked Sendable {
    enum Source: String, Codable { case accessibility, accessibilityRetry, chrome }

    let bundleID: String
    let appName: String
    let pid: Int32
    let windowTitle: String
    let url: String?
    let focused: String?
    let selected: String?
    let elements: [ScreenElement]
    let source: Source
    let readMs: Int
    let takenAt: Date
}

// Cheap enough to poll after acting: did anything the user would notice change?
struct ScreenFingerprint: Equatable, Codable {
    let bundleID: String
    let windowTitle: String
    let windowCount: Int
    let focusedRole: String
    let focusedTitle: String
    let focusedValueLength: Int
    let url: String?
    let childCount: Int
}

enum ScreenElements {
    // Enough for a busy window plus a long sidebar; JayDecide picks which of them fit Jev's choice list.
    static let windowLimit = 300, itemsPerMenu = 25, nodeBudget = 4000
    // Notes once took 30s to walk; past this the command runs on what was read so far.
    static let timeBudget: TimeInterval = 0.5
    static let messagingTimeout: Float = 0.25
    // Chromium builds a page's tree only after a client asks, so the first walk can find it empty.
    static let webRetryDelay: TimeInterval = 0.2
    static let detailLimit = 120, contextLimit = 300
    static let labelLimit = 60

    private static let firstTextDepth = 3
    private static let webAreaSearchBudget = 300
    private static let chromeBundleID = "com.google.Chrome"
    private static let servicesMenu = "Services"
    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    // Never a voice command's target, so they skip the action-names query.
    private static let inertRoles: Set<String> = [
        "AXStaticText", "AXGroup", "AXMenuBarItem", "AXMenu", "AXMenuBar", "AXScrollArea", "AXScrollBar",
        "AXSplitGroup", "AXSplitter", "AXWindow", "AXWebArea", "AXValueIndicator",
    ]
    private static let toggleRoles: Set<String> = ["AXRadioButton", "AXCheckBox"]
    private static let listRoles: Set<String> = ["AXOutline", "AXTable", "AXList"]
    private static let barrenRowLimit = 10
    private static let containerAreas: [String: String] = [
        "AXToolbar": "the toolbar", "AXTabGroup": "the tabs", "AXOutline": "the sidebar list",
        "AXTable": "a list", "AXList": "a list", "AXSheet": "a dialog", "AXPopover": "a popover",
    ]
    private static let selectedState = "selected", checkedState = "checked", focusedState = "focused"
    // AXMenuItemCmdModifiers bits. Command is implied unless the no-command bit is set.
    private static let menuShiftBit = 1, menuOptionBit = 2, menuControlBit = 4, menuNoCommandBit = 8
    private static let keyGlyphs: [String: String] = [
        "\r": "↩", "\u{3}": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "esc", "\u{8}": "⌫", "\u{7f}": "⌫",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦",
    ]
    private static let nodeAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute, kAXEnabledAttribute,
        kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute,
    ]
    // One queue for every walk, so the process-wide messaging timeout is never reset under another read.
    private static let readQueue = DispatchQueue(label: "ai.getbluejay.bisprblow.screen", qos: .userInitiated)

    // MARK: - Snapshot

    static func snapshot(app: NSRunningApplication) async -> ScreenSnapshot {
        let started = Date()
        let pid = app.processIdentifier, bundleID = app.bundleIdentifier ?? "", appName = app.localizedName ?? ""
        guard AXIsProcessTrusted() else {
            return ScreenSnapshot(bundleID: bundleID, appName: appName, pid: pid, windowTitle: "", url: nil, focused: nil,
                                  selected: nil, elements: [], source: .accessibility, readMs: 0, takenAt: started)
        }
        let readsChrome = bundleID == chromeBundleID && ChromeDevTools.isEnabled
        let facts = await onReadQueue { windowFacts(pid: pid, findsWebArea: readsChrome) }
        var page: (url: String?, elements: [ScreenElement])?
        if readsChrome, let read = await ChromeDevTools.shared.read(windowTitle: facts.title, url: facts.webURL, webAreaFrame: facts.webAreaFrame),
           !read.elements.isEmpty {
            page = read
        }
        let skipsWebArea = page != nil
        let walked = await onReadQueue { walkWindowAndMenus(pid: pid, focused: facts.focused, skipsWebArea: skipsWebArea) }

        let inWindow = Array((walked.window.found + (page?.elements ?? [])).prefix(windowLimit))
        let elements = uniquelyLabelled(inWindow + walked.menu)
        let source: ScreenSnapshot.Source = page != nil ? .chrome : walked.isRetry ? .accessibilityRetry : .accessibility
        return ScreenSnapshot(
            bundleID: bundleID, appName: appName, pid: pid, windowTitle: facts.title,
            url: page?.url ?? facts.document ?? walked.webURL ?? facts.webURL,
            focused: walked.window.focusedIndex.map { elements[$0].label } ?? facts.focusedRole,
            selected: walked.window.selectedIndex.map { elements[$0].label },
            elements: elements, source: source,
            readMs: Int(Date().timeIntervalSince(started) * 1000), takenAt: started)
    }

    static func fingerprint() -> ScreenFingerprint {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ScreenFingerprint(bundleID: "", windowTitle: "", windowCount: 0, focusedRole: "", focusedTitle: "",
                                     focusedValueLength: 0, url: nil, childCount: 0)
        }
        let root = bounded(AXUIElementCreateApplication(app.processIdentifier))
        let window = (attribute(root, kAXFocusedWindowAttribute) as AXUIElement?).map(bounded)
        let windowValues = window.map { attributeValues(of: $0, [kAXTitleAttribute, kAXDocumentAttribute]) } ?? [:]
        let focused = (attribute(root, kAXFocusedUIElementAttribute) as AXUIElement?).map(bounded)
        let focusedValues = focused.map { attributeValues(of: $0, [kAXRoleAttribute, kAXTitleAttribute, kAXNumberOfCharactersAttribute]) } ?? [:]
        return ScreenFingerprint(
            bundleID: app.bundleIdentifier ?? "",
            windowTitle: windowValues[kAXTitleAttribute] as? String ?? "",
            windowCount: count(root, kAXWindowsAttribute),
            focusedRole: focusedValues[kAXRoleAttribute] as? String ?? "",
            focusedTitle: focusedValues[kAXTitleAttribute] as? String ?? "",
            focusedValueLength: focusedValues[kAXNumberOfCharactersAttribute] as? Int ?? 0,
            url: windowValues[kAXDocumentAttribute] as? String,
            childCount: window.map { count($0, kAXChildrenAttribute) } ?? 0)
    }

    // MARK: - Pure text

    // Apple's glyph order, ⌃⌥⇧⌘ then the key, so it equals `Shortcut.display` for the same key.
    static func shortcutText(cmdChar: String, modifiers: Int) -> String {
        var glyphs = ""
        if modifiers & menuControlBit != 0 { glyphs += "⌃" }
        if modifiers & menuOptionBit != 0 { glyphs += "⌥" }
        if modifiers & menuShiftBit != 0 { glyphs += "⇧" }
        if modifiers & menuNoCommandBit == 0 { glyphs += "⌘" }
        return glyphs + (keyGlyphs[cmdChar] ?? cmdChar.uppercased())
    }

    // What a menu button or section header reveals; such a control is never the page its name points to.
    static let revealsWhat = "menu or section"

    static func detail(roleDescription: String, place: String?, help: String?, shortcut: String?, states: [String]) -> String {
        let head = [roleDescription, place ?? ""].filter { !$0.isEmpty }.joined(separator: " in ")
        let helpText = help?.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        let parts = [head, helpText ?? "", shortcut ?? ""] + states
        return String(parts.filter { !$0.isEmpty }.joined(separator: ". ").prefix(detailLimit))
    }

    // Jev's choices are keyed by label, so two "Close (button)"s would collapse into one. Checked
    // against every label taken, since a real element can already be called "Close (button) #2".
    static func uniquelyLabelled(_ elements: [ScreenElement]) -> [ScreenElement] {
        var taken = Set<String>()
        return elements.map { element in
            var label = element.label, count = 1
            while !taken.insert(label).inserted {
                count += 1
                label = "\(element.label) #\(count)"
            }
            return element.with(label: label)
        }
    }

    static func attribute<T>(_ node: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: - Reading

    private struct WindowFacts: @unchecked Sendable {
        var title = ""
        var document: String?
        var focused: AXUIElement?
        var focusedRole: String?
        var webURL: String?
        var webAreaFrame: CGRect?
    }

    private struct Place {
        var area = "the window"
        var titles: [String] = []
        var menuPath: [String] = []
        var isInWebArea = false
    }

    private struct WalkState {
        let limit: Int
        let deadline: Date
        let skipsWebArea: Bool
        let focused: AXUIElement?
        var budget = ScreenElements.nodeBudget
        var found: [ScreenElement] = []
        var selectedIndex: Int?
        var focusedIndex: Int?
        var webArea: AXUIElement?
        var foundInWebArea = 0
        // Chrome hands out its tab strip and toolbar several times over, one copy per path to the same view.
        var seen: Set<String> = []
    }

    private struct Walked: @unchecked Sendable {
        let window: WalkState
        let menu: [ScreenElement]
        let webURL: String?
        let isRetry: Bool
    }

    private static func onReadQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in readQueue.async { continuation.resume(returning: work()) } }
    }

    private static func windowFacts(pid: pid_t, findsWebArea: Bool) -> WindowFacts {
        let root = AXUIElementCreateApplication(pid)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }
        // Chromium and Electron build their tree only for a client that asks for it this way.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var facts = WindowFacts()
        facts.focused = attribute(root, kAXFocusedUIElementAttribute)
        facts.focusedRole = facts.focused.flatMap { attribute($0, kAXRoleDescriptionAttribute) }
        guard let window: AXUIElement = attribute(root, kAXFocusedWindowAttribute) else { return facts }
        facts.title = attribute(window, kAXTitleAttribute) ?? ""
        facts.document = nonEmpty(attribute(window, kAXDocumentAttribute))
        if findsWebArea, let webArea = firstWebArea(in: window) {
            facts.webURL = webURL(of: webArea)
            facts.webAreaFrame = frame(attributeValues(of: webArea, [kAXPositionAttribute, kAXSizeAttribute]))
        }
        return facts
    }

    private static func walkWindowAndMenus(pid: pid_t, focused: AXUIElement?, skipsWebArea: Bool) -> Walked {
        let root = AXUIElementCreateApplication(pid)
        // A busy app answers each query late, and thousands of late answers add up to seconds. The
        // timeout is process-wide, so it goes back to the default for dictation's own reads.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }

        let window: AXUIElement? = attribute(root, kAXFocusedWindowAttribute)
        var windowState = walkWindow(window, focused: focused, skipsWebArea: skipsWebArea)
        // Focus on the page with no web area in the tree is Chrome before it has built the page for us.
        let isFocusOnPage = focused.flatMap { attribute($0, kAXRoleAttribute) as String? } == "AXWebArea"
        let isRetry = !skipsWebArea && (windowState.webArea != nil || isFocusOnPage) && windowState.foundInWebArea == 0
        if isRetry {
            Thread.sleep(forTimeInterval: webRetryDelay)
            windowState = walkWindow(window, focused: focused, skipsWebArea: false)
        }
        // Each menu gets its own allowance, or Open Recent in File leaves View and History none.
        let deadline = Date().addingTimeInterval(timeBudget)
        // The first menu is Apple's: Restart, Shut Down and Log Out are never a voice command's to press.
        let menus = (attribute(root, kAXMenuBarAttribute) as AXUIElement?)
            .flatMap { attribute($0, kAXChildrenAttribute) as [AXUIElement]? } ?? []
        let menuItems = menus.dropFirst().map { item in
            var menuState = WalkState(limit: itemsPerMenu, deadline: deadline, skipsWebArea: false, focused: nil)
            walk(item, place: Place(), into: &menuState)
            return menuState.found
        }
        return Walked(window: windowState, menu: interleaved(menuItems), webURL: windowState.webArea.flatMap(webURL), isRetry: isRetry)
    }

    // Item n of every menu before item n+1 of any, so cutting the list anywhere leaves each menu its share.
    static func interleaved<T>(_ lists: [[T]]) -> [T] {
        (0..<(lists.map(\.count).max() ?? 0)).flatMap { rank in lists.compactMap { rank < $0.count ? $0[rank] : nil } }
    }

    private static func walkWindow(_ window: AXUIElement?, focused: AXUIElement?, skipsWebArea: Bool) -> WalkState {
        var state = WalkState(limit: windowLimit, deadline: Date().addingTimeInterval(timeBudget), skipsWebArea: skipsWebArea, focused: focused)
        if let window { walk(window, place: Place(), into: &state) }
        // A slow app can run out the walk before it reaches the cursor, and the cursor is where typing goes.
        if state.focusedIndex == nil, let focused, let field = focusedField(focused) {
            if state.found.count >= state.limit {
                state.found.removeLast()
                if state.selectedIndex == state.found.count { state.selectedIndex = nil }
            }
            state.focusedIndex = state.found.count
            state.found.append(field)
        }
        return state
    }

    private static func focusedField(_ node: AXUIElement) -> ScreenElement? {
        let values = attributeValues(of: node, nodeAttributes)
        guard let role = values[kAXRoleAttribute] as? String, fieldRoles.contains(role),
              let found = candidate(node, role: role, values: values, isFocused: true)
        else { return nil }
        return element(node, name: found.name, kind: found.kind, role: role, values: values, place: Place(), states: [focusedState])
    }

    private static func walk(_ node: AXUIElement, place: Place, into state: inout WalkState) {
        guard state.budget > 0, state.found.count < state.limit, Date() < state.deadline else { return }
        state.budget -= 1
        let values = attributeValues(of: node, nodeAttributes)
        let role = values[kAXRoleAttribute] as? String ?? ""
        let title = nonEmpty(values[kAXTitleAttribute] as? String)
        if role == "AXWebArea" {
            if state.webArea == nil { state.webArea = node }
            if state.skipsWebArea { return }
        }
        // Services are other apps' commands, offered for whatever is selected.
        if role == "AXMenuItem", title == servicesMenu { return }

        let isFocused = state.focused.map { CFEqual(node, $0) } ?? false
        if values[kAXEnabledAttribute] as? Bool != false, let found = candidate(node, role: role, values: values, isFocused: isFocused),
           isFirstCopy(role: role, name: found.name, values: values, in: &state) {
            let elementStates = states(of: node, role: role, values: values, focused: state.focused)
            if elementStates.contains(selectedState), state.selectedIndex == nil { state.selectedIndex = state.found.count }
            if elementStates.contains(focusedState) { state.focusedIndex = state.found.count }
            state.found.append(element(node, name: found.name, kind: found.kind, role: role, values: values, place: place, states: elementStates))
            if place.isInWebArea { state.foundInWebArea += 1 }
        }

        let inner = innerPlace(place, role: role, title: title)
        var barrenRows = 0
        // A collapsed menu's items are still in the tree, which is what makes the menu bar readable.
        for child in values[kAXChildrenAttribute] as? [AXUIElement] ?? [] {
            // Rows that hold nothing to press (Notes' note list, Finder's files) cost the walk its time
            // budget; a table's header after them still holds the sort buttons.
            if barrenRows >= barrenRowLimit {
                if let header: AXUIElement = attribute(node, kAXHeaderAttribute) { walk(header, place: inner, into: &state) }
                break
            }
            let index = state.found.count
            walk(child, place: inner, into: &state)
            if listRoles.contains(role) { barrenRows = state.found.count == index ? barrenRows + 1 : 0 }
        }
    }

    private static func isFirstCopy(role: String, name: String, values: [String: AnyObject], in state: inout WalkState) -> Bool {
        guard let box = frame(values), !box.isEmpty else { return true }
        return state.seen.insert("\(role)|\(name)|\(box.origin.x),\(box.origin.y),\(box.width),\(box.height)").inserted
    }

    private static func innerPlace(_ place: Place, role: String, title: String?) -> Place {
        var inner = place
        if role == "AXWebArea" {
            // The page title is already the window title; repeating it would spend the detail budget.
            inner.area = "the page"
            inner.isInWebArea = true
        } else if let area = containerAreas[role] {
            inner.area = title.map { "\(area) \"\($0)\"" } ?? area
            if let title { inner.titles.append(title) }
        }
        if role == "AXMenuBarItem" || role == "AXMenuItem", let title { inner.menuPath.append(title) }
        return inner
    }

    private static func candidate(_ node: AXUIElement, role: String, values: [String: AnyObject], isFocused: Bool) -> (name: String, kind: ScreenElement.Kind)? {
        guard !inertRoles.contains(role) else { return nil }
        let named = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .lazy.compactMap { nonEmpty(values[$0] as? String) }.first
        if fieldRoles.contains(role) {
            // A document's own text area has no name, and it is where "type …" goes when it holds the cursor.
            let fallback = isFocused ? nonEmpty(values[kAXRoleDescriptionAttribute] as? String) : nil
            guard values[kAXSubroleAttribute] as? String != "AXSecureTextField", let name = named ?? fallback else { return nil }
            return (name, .field)
        }
        guard actions(of: node).contains(kAXPressAction as String),
              let name = named ?? firstText(under: node, depth: firstTextDepth) else { return nil }
        return (name, .press)
    }

    private static func states(of node: AXUIElement, role: String, values: [String: AnyObject], focused: AXUIElement?) -> [String] {
        var states: [String] = []
        let isOn = toggleRoles.contains(role) && (attribute(node, kAXValueAttribute) as Int?) == 1
        if values[kAXSelectedAttribute] as? Bool == true || (isOn && role != "AXCheckBox") { states.append(selectedState) }
        if isOn && role == "AXCheckBox" { states.append(checkedState) }
        if let focused, CFEqual(node, focused) { states.append(focusedState) }
        return states
    }

    private static func element(_ node: AXUIElement, name: String, kind: ScreenElement.Kind, role: String,
                                values: [String: AnyObject], place: Place, states: [String]) -> ScreenElement {
        let roleDescription = nonEmpty(values[kAXRoleDescriptionAttribute] as? String) ?? role
        let shortcut = nonEmpty(values[kAXMenuItemCmdCharAttribute] as? String)
            .map { shortcutText(cmdChar: $0, modifiers: values[kAXMenuItemCmdModifiersAttribute] as? Int ?? 0) }
        let area = role == "AXMenuItem"
            ? (place.menuPath.isEmpty ? "the menu bar" : "the menu " + place.menuPath.joined(separator: " > "))
            : place.area
        let help = nonEmpty(values[kAXHelpAttribute] as? String).flatMap { $0 == name ? nil : $0 }
        return ScreenElement(
            label: "\(name.prefix(labelLimit)) (\(roleDescription))", kind: kind, role: role,
            detail: detail(roleDescription: roleDescription, place: area, help: help, shortcut: shortcut, states: states),
            context: String(place.titles.joined(separator: " > ").prefix(contextLimit)),
            shortcut: shortcut, frame: frame(values), handle: .ax(node),
            riskText: [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { values[$0] as? String }.joined(separator: " "))
    }

    private static func firstText(under node: AXUIElement, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for child in (attribute(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (attribute(child, kAXRoleAttribute) as String?) == "AXStaticText", let value = nonEmpty(attribute(child, kAXValueAttribute)) {
                return value
            }
            if let text = firstText(under: child, depth: depth - 1) { return text }
        }
        return nil
    }

    private static func firstWebArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window], budget = webAreaSearchBudget
        while !queue.isEmpty, budget > 0 {
            let node = queue.removeFirst()
            budget -= 1
            let values = attributeValues(of: node, [kAXRoleAttribute, kAXChildrenAttribute])
            if values[kAXRoleAttribute] as? String == "AXWebArea" { return node }
            queue += values[kAXChildrenAttribute] as? [AXUIElement] ?? []
        }
        return nil
    }

    private static func webURL(of webArea: AXUIElement) -> String? {
        (attribute(webArea, kAXURLAttribute) as URL?)?.absoluteString
    }

    // MARK: - AX plumbing

    // One round trip for many attributes; the ones a node lacks are dropped rather than returned as errors.
    private static func attributeValues(of node: AXUIElement, _ names: [String]) -> [String: AnyObject] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray, [], &raw) == .success,
              let list = raw as? [AnyObject] else { return [:] }
        var result: [String: AnyObject] = [:]
        for (name, value) in zip(names, list) where !isError(value) { result[name] = value }
        return result
    }

    private static func isError(_ value: AnyObject) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
    }

    private static func frame(_ values: [String: AnyObject]) -> CGRect? {
        guard let position = values[kAXPositionAttribute], let size = values[kAXSizeAttribute],
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func actions(of node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func count(_ node: AXUIElement, _ name: String) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, name as CFString, &count) == .success else { return 0 }
        return count
    }

    // Per-element timeout, for reads on the main thread that must not wait out a hung app.
    private static func bounded(_ node: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(node, messagingTimeout)
        return node
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension ScreenElement {
    func with(label: String) -> ScreenElement {
        ScreenElement(label: label, kind: kind, role: role, detail: detail, context: context, shortcut: shortcut, frame: frame,
                      handle: handle, riskText: riskText)
    }
}
