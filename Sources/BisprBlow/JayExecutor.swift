import AppKit
import ApplicationServices
import Carbon.HIToolbox

// What a pressed element looked like, read alongside the fingerprint: a checkbox, tab or row that
// toggles in place changes nothing the fingerprint sees, and calling that "unchanged" would fire
// the runner-up on top of an action that worked.
enum JayOutcome: String, Codable, Sendable { case done, unchanged, failed, needsConfirmation }

private struct TargetState: Equatable {
    let isAlive: Bool
    let value: Double?
    let isSelected: Bool?
}

private struct Observation {
    let screen: ScreenFingerprint
    let target: TargetState?
}

// Carries out what JayDecide picked and checks the screen moved. `run` is the only way to act, so
// the ask-first gate for send, delete, pay and the rest cannot be skipped by any caller.
@MainActor
enum JayExecutor {
    static let verifyTimeout: TimeInterval = 0.8
    static let verifyInterval: TimeInterval = 0.05
    static let undoWindow: TimeInterval = 60

    private static let keyGap: useconds_t = 10_000
    nonisolated private static let enterActionID = "enter"
    private static let undoShortcut = Shortcut(trigger: .key(kVK_ANSI_Z), flags: CGEventFlags.maskCommand.rawValue)
    // NX_SYSDEFINED media key events: subtype 8, key state 0xA down / 0xB up (IOKit ev_keymap.h).
    private static let mediaKeySubtype: Int16 = 8
    nonisolated private static let mediaKeyDown = 0xA
    nonisolated private static let mediaKeyUp = 0xB
    private static let unusedEventData = -1

    private static var lastUndoable: (bundleID: String, at: TimeInterval)?

    static func run(_ action: JayAction, command: String, isWakeListening: Bool, screen: ScreenSnapshot, confirmed: Bool) async -> JayOutcome {
        guard confirmed || !isRisky(action, command: command, isWakeListening: isWakeListening) else { return .needsConfirmation }
        defer { ScreenWatcher.shared.invalidateWithReads() }
        let target = pressedElement(of: action)
        let before = isVerifiable(action) ? await observe(target) : nil
        guard await perform(action, pid: screen.pid) else { return .failed }
        if let before, await !hasChanged(since: before, target: target) { return .unchanged }
        if isUndoable(action) { lastUndoable = (screen.bundleID, ProcessInfo.processInfo.systemUptime) }
        return .done
    }

    // `isCurrent` turns false on Esc or "stop", which must not be answered with a second action.
    static func runWithFallback(_ decision: JayDecision, command: String, isWakeListening: Bool, screen: ScreenSnapshot, isCurrent: () -> Bool) async -> JayOutcome {
        guard let action = decision.action else { return .failed }
        let outcome = await run(action, command: command, isWakeListening: isWakeListening, screen: screen, confirmed: false)
        guard outcome == .unchanged, isCurrent(), let runnerUp = decision.runnerUp, runnerUp.key != action.key,
              !isRisky(runnerUp, command: command, isWakeListening: isWakeListening)
        else { return outcome }
        logLine("jay act runnerUp")
        return await run(runnerUp, command: command, isWakeListening: isWakeListening, screen: screen, confirmed: false)
    }

    static func undoLast() -> Bool {
        guard let last = lastUndoable, ProcessInfo.processInfo.systemUptime - last.at <= undoWindow,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.bundleID
        else { return false }
        lastUndoable = nil
        defer { ScreenWatcher.shared.invalidateWithReads() }
        return postKeys(undoShortcut)
    }

    // Screen text is not the user: a page can show a "Delete account" button, so the label counts
    // as much as the command does. Typing is left out because it is undone with ⌘Z. Return sends a
    // message or runs a shell command almost anywhere, so it goes unasked only when the user named it
    // while holding the shortcut: a wake word can come from call audio or anyone in the room.
    nonisolated static func isRisky(_ action: JayAction, command: String, isWakeListening: Bool) -> Bool {
        if VoiceCommand.hasRiskyWord(command) { return true }
        switch action {
        case .press(let element):
            return element.kind == .press && (VoiceCommand.hasRiskyWord(element.label) || VoiceCommand.hasRiskyWord(element.riskText))
        case .system(let system):
            return VoiceCommand.hasRiskyWord(system.title)
                || (system.id == enterActionID && (isWakeListening || !system.phrases.contains(JayDecide.normalized(command))))
        case .type, .openApp, .openURL:
            return false
        }
    }

    nonisolated static func didChange(_ before: ScreenFingerprint, _ after: ScreenFingerprint) -> Bool { before != after }

    nonisolated static func mediaKeyData(_ keyType: Int32, isDown: Bool) -> Int {
        (Int(keyType) << 16) | ((isDown ? mediaKeyDown : mediaKeyUp) << 8)
    }

    // MARK: - Verifying

    nonisolated private static func isVerifiable(_ action: JayAction) -> Bool {
        if case .system(let system) = action { return system.isVerifiable }
        return true
    }

    nonisolated private static func isUndoable(_ action: JayAction) -> Bool {
        switch action {
        case .press, .type: return true
        case .system(let system):
            if case .keys = system.mechanism { return true }
            return false
        case .openApp, .openURL: return false
        }
    }

    nonisolated private static func pressedElement(of action: JayAction) -> ScreenElement? {
        if case .press(let element) = action, element.kind == .press { return element }
        return nil
    }

    // AX reads block on the target app, so they stay off the main thread.
    nonisolated private static func observe(_ target: ScreenElement?) async -> Observation {
        await Task.detached { Observation(screen: ScreenElements.fingerprint(), target: Self.targetState(of: target)) }.value
    }

    nonisolated private static func targetState(of element: ScreenElement?) -> TargetState? {
        guard case .ax(let node)? = element?.handle else { return nil }
        return TargetState(isAlive: (ScreenElements.attribute(node, kAXRoleAttribute) as String?) != nil,
                           value: (ScreenElements.attribute(node, kAXValueAttribute) as NSNumber?)?.doubleValue,
                           isSelected: ScreenElements.attribute(node, kAXSelectedAttribute))
    }

    private static func hasChanged(since before: Observation, target: ScreenElement?) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + verifyTimeout
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(verifyInterval))
            let after = await observe(target)
            if didChange(before.screen, after.screen) || before.target != after.target { return true }
        }
        // Esc mid-wait leaves it unknown, and unknown must not fire the runner-up or "Couldn't do that".
        return Task.isCancelled
    }

    // MARK: - Performing

    private static func perform(_ action: JayAction, pid: Int32) async -> Bool {
        switch action {
        case .press(let element): return await pressElement(element, pid: pid)
        case .type(let text, let field): return await typeText(text, into: field, pid: pid)
        case .system(let system): return await performSystem(system)
        case .openApp(let app): return await openApp(at: URL(fileURLWithPath: app.path))
        case .openURL(let url): return await openURL(url)
        }
    }

    // A field is "pressed" by focusing it.
    private static func pressElement(_ element: ScreenElement, pid: Int32) async -> Bool {
        switch element.handle {
        case .chrome(let index, let generation)?:
            if element.kind == .field { return await ChromeDevTools.shared.focus(index: index, generation: generation) }
            return await ChromeDevTools.shared.press(index: index, generation: generation)
        case .ax(let node)?:
            // AX calls wait on the target app, and the shortcut's event tap shares the main thread.
            return await Task.detached { pressOnScreen(node, element: element, pid: pid) }.value
        case nil:
            return fail("noHandle")
        }
    }

    nonisolated private static func pressOnScreen(_ node: AXUIElement, element: ScreenElement, pid: Int32) -> Bool {
        AXUIElementSetMessagingTimeout(node, ScreenElements.messagingTimeout)
        guard (ScreenElements.attribute(node, kAXRoleAttribute) as String?) != nil else { return fail("stale") }
        guard (ScreenElements.attribute(node, kAXEnabledAttribute) as Bool?) != false else { return fail("disabled") }
        guard isUncovered(element, pid: pid) else { return fail("covered") }
        if element.kind == .field { return focusField(node, pid: pid) }
        // A press that opens a modal sheet does not answer until the sheet closes, so the short
        // timeout reports cannotComplete for a press that happened; verifying decides.
        let result = AXUIElementPerformAction(node, kAXPressAction as CFString)
        return result == .success || result == .cannotComplete || fail("press")
    }

    // Another app's window over the element's centre means the snapshot is not what is on screen.
    // Our own badges and toast float over everything and do not count.
    nonisolated private static func isUncovered(_ element: ScreenElement, pid: Int32) -> Bool {
        guard !element.isMenuItem, let frame = element.frame, !frame.isEmpty else { return true }
        var hit: AXUIElement?
        var hitPid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(frame.midX), Float(frame.midY), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &hitPid) == .success
        else { return true }
        return hitPid == pid || hitPid == ProcessInfo.processInfo.processIdentifier
    }

    nonisolated private static func focusField(_ node: AXUIElement, pid: Int32) -> Bool {
        guard AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return fail("focus") }
        // Setting focus can report success without moving it, and the paste goes wherever focus is.
        guard let focused = focusedElement(in: pid), CFEqual(focused, node) else { return fail("focus") }
        return true
    }

    nonisolated private static func focusedElement(in pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ScreenElements.messagingTimeout)
        return ScreenElements.attribute(app, kAXFocusedUIElementAttribute)
    }

    private static func typeText(_ text: String, into field: ScreenElement?, pid: Int32) async -> Bool {
        if let field {
            guard await pressElement(field, pid: pid) else { return false }
        } else {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  await Task.detached(operation: { focusedElement(in: pid).map(isTypeable) ?? false }).value
            else { return fail("notText") }
        }
        return await TextInserter.insertAndWait(text) || fail("paste")
    }

    // Never a password field: what is said there would be spoken aloud and sent to Jev.
    nonisolated private static func isTypeable(_ node: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(node, ScreenElements.messagingTimeout)
        guard (ScreenElements.attribute(node, kAXSubroleAttribute) as String?) != "AXSecureTextField",
              let role: String = ScreenElements.attribute(node, kAXRoleAttribute)
        else { return false }
        return ScreenElements.fieldRoles.contains(role)
    }

    private static func performSystem(_ system: SystemAction) async -> Bool {
        switch system.mechanism {
        case .keys(let shortcut): return postKeys(shortcut)
        case .scroll(let pixels): return postScroll(pixels)
        case .media(let keyType): return postMediaKey(keyType)
        case .script(let source): return await runScript(source)
        case .launch(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return fail("noApp") }
            return await openApp(at: url)
        }
    }

    private static func postKeys(_ shortcut: Shortcut) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard AXIsProcessTrusted(), case .key(let code) = shortcut.trigger,
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        else { return fail("keys") }
        down.flags = CGEventFlags(rawValue: shortcut.flags)
        up.flags = down.flags
        down.post(tap: .cghidEventTap)
        usleep(keyGap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // Spoken "down" means the content moves up, which is a negative wheel delta.
    private static func postScroll(_ pixels: Int32) -> Bool {
        guard AXIsProcessTrusted(),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0)
        else { return fail("scroll") }
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postMediaKey(_ keyType: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return fail("media") }
        for isDown in [true, false] {
            let state = isDown ? mediaKeyDown : mediaKeyUp
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: mediaKeySubtype,
                                                 data1: mediaKeyData(keyType, isDown: isDown), data2: unusedEventData)?.cgEvent
            else { return fail("media") }
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    nonisolated private static func runScript(_ source: String) async -> Bool {
        await Task.detached {
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            guard let error else { return true }
            let code = (error[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "none"
            logLine("jay act failed reason=script code=\(code)")
            return false
        }.value
    }

    private static func openApp(at url: URL) async -> Bool {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            logLine("jay act failed reason=openApp code=\((error as NSError).code)")
            return false
        }
    }

    private static func openURL(_ url: URL) async -> Bool {
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            logLine("jay act failed reason=openURL code=\((error as NSError).code)")
            return false
        }
    }

    nonisolated private static func fail(_ reason: String) -> Bool {
        logLine("jay act failed reason=\(reason)")
        return false
    }
}
