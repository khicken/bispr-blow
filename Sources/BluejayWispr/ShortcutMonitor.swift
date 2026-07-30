import AppKit
import Carbon.HIToolbox

/// Global shortcut detection: watches the user's bindings (`AppSettings.bindings`) and turns
/// them into dictation gestures.
///
/// Gestures on a push-to-talk binding:
/// - Hold (≥ holdThreshold) → `onStart` fires on key-down, `onStop` on release.
/// - Double-tap → hands-free lock: recording continues until the next tap or a cancel binding.
/// - Single short tap → `onCancel` (recording that started on key-down is discarded).
///
/// Primary mechanism is an active CGEventTap that *consumes* the events a binding claims, so a
/// bare-fn binding never lets the macOS "Press 🌐 key to…" action fire, and a ⌃⌥D binding never
/// reaches the app underneath. Everything unbound passes straight through. Falls back to passive
/// NSEvent monitors if the tap can't be created.
/// Requires Accessibility trust (tap creation also prompts Input Monitoring on macOS 15+).
final class ShortcutMonitor {
    /// One monitor per process by construction — two taps would fight over the same events.
    /// Shared so Settings can arm the recorder without threading the controller through the UI.
    static let shared = ShortcutMonitor()

    /// `sendEnter` is true when the binding that started this session was "Dictate and send".
    var onStart: ((_ sendEnter: Bool) -> Void)?
    /// locked == true when stopping a hands-free session.
    var onStop: ((_ locked: Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when a double-tap upgrades the session to hands-free.
    var onLock: (() -> Void)?

    private let holdThreshold: TimeInterval = 0.30
    private let doubleTapWindow: TimeInterval = 0.40

    private var triggerIsDown = false
    private var triggerDownAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = -10
    private var locked = false
    private var pendingCancel: DispatchWorkItem?
    /// Which action is holding the current session: a release only counts from the same binding,
    /// so letting go of "dictate and send" can't end a push-to-talk hold.
    private var heldAction: ShortcutAction?
    /// Set when we swallowed a cancel key-down, so its key-up gets swallowed to match.
    private var swallowedCancelDown = false

    private var bindings: [(ShortcutAction, Shortcut)] = []
    private var started = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var retryTimer: Timer?
    private var nsMonitors: [Any] = []

    func start() {
        started = true
        reload()
        if !startEventTap() {
            logLine("CGEventTap unavailable (missing Accessibility?); using passive NSEvent fallback")
            startNSEventFallback()
            // Upgrade to the tap as soon as Accessibility is granted — no relaunch needed.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.startEventTap() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.nsMonitors.forEach { NSEvent.removeMonitor($0) }
                    self.nsMonitors = []
                    logLine("Accessibility granted — upgraded to CGEventTap")
                }
            }
        }
    }

    /// Pick up edited bindings, and suppress the macOS fn action only while fn is actually bound.
    func reload() {
        bindings = AppSettings.shared.allBindings
        guard started else { return }  // --self-check must never touch the user's HIToolbox prefs
        SystemFnKey.sync(suppress: AppSettings.shared.fnIsBound)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        watchdog?.invalidate()
        watchdog = nil
        retryTimer?.invalidate()
        retryTimer = nil
        nsMonitors.forEach { NSEvent.removeMonitor($0) }
        nsMonitors = []
    }

    /// Stop a hands-free session from the UI (pill stop button).
    func endLockedSession() {
        guard locked else { return }
        locked = false
        onStop?(true)
    }

    /// Start a hands-free session from the UI (pill buttons) — same as double-tapping.
    func beginLockedSession() {
        guard !locked, !triggerIsDown else { return }
        locked = true
        onStart?(false)
        onLock?()
    }

    // MARK: - Recording a new binding

    private var captureHandler: ((Shortcut) -> Void)?
    /// First modifier pressed while armed, held until we know whether it is a standalone
    /// binding (released on its own) or the start of a combo (a real key followed).
    private var capturePending: Int?

    var isCapturing: Bool { captureHandler != nil }

    /// Arm the recorder: the next key or mouse combination goes to `handler` instead of firing
    /// any binding, and never reaches the app underneath.
    func beginCapture(_ handler: @escaping (Shortcut) -> Void) {
        capturePending = nil
        captureHandler = handler
    }

    func endCapture() {
        captureHandler = nil
        capturePending = nil
    }

    // MARK: - CGEventTap path

    private func startEventTap() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(into: UInt64(0)) { $0 |= 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
                return monitor.handleTapEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // macOS disables taps it deems slow; quietly re-arm.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return true
    }

    /// Runs on the main run loop (source is attached there). Must stay fast.
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .flagsChanged, .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if capture(type: type, keyCode: code, mouseButton: nil, flags: event.flags) { return nil }
            guard let (action, down) = keyMatch(
                keyCode: code, flags: event.flags,
                isFlagsChanged: type == .flagsChanged, isKeyDown: type == .keyDown
            ) else { return pass }
            return dispatch(action, down: down) ? nil : pass
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if capture(type: type, keyCode: nil, mouseButton: button, flags: event.flags) { return nil }
            guard let action = action(matching: { $0.matches(mouseButton: button) }) else { return pass }
            return dispatch(action, down: type == .otherMouseDown) ? nil : pass
        default:
            return pass
        }
    }

    private func action(matching predicate: (Shortcut) -> Bool) -> ShortcutAction? {
        bindings.first { predicate($0.1) }?.0
    }

    /// Feeds the Settings recorder. Returns true when the event was consumed by it.
    private func capture(type: CGEventType, keyCode: Int?, mouseButton: Int?, flags: CGEventFlags) -> Bool {
        guard let handler = captureHandler else { return false }
        let tracked = flags.intersection(Shortcut.tracked)
        switch type {
        case .flagsChanged:
            guard let code = keyCode, let flag = Shortcut.modifierFlags[code] else { return true }
            if flags.contains(flag) {
                if capturePending == nil { capturePending = code }
            } else if tracked.isEmpty, let pending = capturePending {
                commit(Shortcut(trigger: .key(pending)), to: handler)
            }
        case .keyDown:
            guard let code = keyCode else { return true }
            commit(Shortcut(trigger: .key(code), flags: tracked.rawValue), to: handler)
        case .otherMouseDown:
            guard let button = mouseButton else { return true }
            commit(Shortcut(trigger: .mouse(button)), to: handler)
        default:
            break  // key-up / mouse-up while armed: swallow, don't record
        }
        return true
    }

    private func commit(_ shortcut: Shortcut, to handler: @escaping (Shortcut) -> Void) {
        endCapture()
        // Off the tap callback: the handler persists settings and re-reads the HIToolbox prefs,
        // and macOS disables a tap that takes too long to answer.
        DispatchQueue.main.async { handler(shortcut) }
    }

    // MARK: - Dispatch

    private var sessionIsLive: Bool { locked || triggerIsDown }

    /// Returns true when the event should be swallowed rather than passed to the app underneath.
    private func dispatch(_ action: ShortcutAction, down: Bool) -> Bool {
        switch action {
        case .pushToTalk, .pressEnter:
            handleHold(action, down: down)
            return true
        case .handsFree:
            guard down else { return true }
            if locked {
                locked = false
                onStop?(true)
            } else if !triggerIsDown {
                beginLockedSession()
            }
            return true
        case .cancel:
            guard down else {
                defer { swallowedCancelDown = false }
                return swallowedCancelDown
            }
            // Esc is the shipped default: only eat it while there is something to throw away.
            guard sessionIsLive else { return false }
            cancelSession()
            swallowedCancelDown = true
            return true
        }
    }

    private func cancelSession() {
        pendingCancel?.cancel()
        pendingCancel = nil
        locked = false
        // Clear the hold too, so the physical release of a still-held trigger is a no-op
        // rather than a second stop.
        triggerIsDown = false
        heldAction = nil
        lastTapAt = -10
        onCancel?()
    }

    // MARK: - NSEvent fallback (observe-only)

    private func startNSEventFallback() {
        let masks: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { [weak self] event in
            guard let self, !self.isCapturing else { return }
            switch event.type {
            case .otherMouseDown, .otherMouseUp:
                let button = event.buttonNumber
                guard let action = self.action(matching: { $0.matches(mouseButton: button) }) else { return }
                _ = self.dispatch(action, down: event.type == .otherMouseDown)
            default:
                // NSEvent.ModifierFlags shares CGEventFlags' bit layout, so no translation
                // table — and unlike `event.cgEvent` it is never nil.
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                guard let (action, down) = self.keyMatch(
                    keyCode: Int(event.keyCode), flags: flags,
                    isFlagsChanged: event.type == .flagsChanged, isKeyDown: event.type == .keyDown
                ) else { return }
                _ = self.dispatch(action, down: down)
            }
        }) { nsMonitors.append(monitor) }
    }

    /// Which action a key event fires, and whether it is a press or a release.
    /// A modifier key only ever arrives as flagsChanged and an ordinary key only as
    /// keyDown/keyUp: crossing them would double-fire on fn+arrow style events, where the
    /// arrow's keyDown also carries the fn flag.
    private func keyMatch(keyCode: Int, flags: CGEventFlags, isFlagsChanged: Bool,
                          isKeyDown: Bool) -> (ShortcutAction, Bool)? {
        let modifierFlag = Shortcut.modifierFlags[keyCode]
        guard (modifierFlag != nil) == isFlagsChanged,
              let action = action(matching: { $0.matches(keyCode: keyCode, flags: flags) })
        else { return nil }
        // A modifier's press/release is the presence of its flag; an ordinary key's is the
        // event type.
        return (action, modifierFlag.map { flags.contains($0) } ?? isKeyDown)
    }

    /// Test seam for `--self-check`: drives the gesture machine with no event tap in the way.
    /// Returns whether the event would have been swallowed.
    func simulate(_ action: ShortcutAction, down: Bool) -> Bool {
        dispatch(action, down: down)
    }

    // MARK: - Gesture state machine

    /// The hold-versus-double-tap machine, unchanged apart from *which* binding drives it.
    private func handleHold(_ action: ShortcutAction, down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        if down, !triggerIsDown {
            triggerIsDown = true
            triggerDownAt = now
            heldAction = action
            pendingCancel?.cancel()
            pendingCancel = nil

            if locked {
                // Tap while locked → stop and process.
                locked = false
                onStop?(true)
                lastTapAt = -10
                return
            }
            if now - lastTapAt <= doubleTapWindow {
                // Second tap of a double-tap → lock hands-free mode (already recording).
                locked = true
                lastTapAt = -10
                onLock?()
                return
            }
            onStart?(action == .pressEnter)
        } else if !down, triggerIsDown, heldAction == action {
            triggerIsDown = false
            heldAction = nil
            if locked { return }  // release of the second tap; session stays live
            let heldFor = now - triggerDownAt
            if heldFor >= holdThreshold {
                onStop?(false)
                lastTapAt = -10
            } else {
                // Short tap: wait out the double-tap window before discarding.
                lastTapAt = now
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.locked else { return }
                    self.onCancel?()
                }
                pendingCancel = work
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
            }
        }
    }
}
