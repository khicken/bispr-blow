import AppKit
import Carbon.HIToolbox

/// Global Fn-key gesture detection.
///
/// Gestures:
/// - Hold Fn (≥ holdThreshold) → push-to-talk: `onStart` fires on key-down, `onStop` on release.
/// - Double-tap Fn (two quick taps) → hands-free lock: recording continues until the next
///   Fn tap or Esc.
/// - Single short tap → `onCancel` (recording that started on key-down is discarded).
///
/// Primary mechanism is an active CGEventTap that *consumes* bare-Fn flagsChanged events,
/// so the macOS "Press 🌐 key to…" action (emoji picker / system dictation) never fires —
/// no need to change the user's system setting. Other Fn combos (fn+arrows etc.) are
/// untouched: only keycode-63 flagsChanged events are swallowed; keyDown events pass through.
/// Falls back to passive NSEvent monitors if the tap can't be created.
/// Requires Accessibility trust (tap creation also prompts Input Monitoring on macOS 15+).
final class FnKeyMonitor {
    var onStart: (() -> Void)?
    /// locked == true when stopping a hands-free session.
    var onStop: ((_ locked: Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when a double-tap upgrades the session to hands-free.
    var onLock: (() -> Void)?

    private let holdThreshold: TimeInterval = 0.30
    private let doubleTapWindow: TimeInterval = 0.40

    private var fnIsDown = false
    private var fnDownAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = -10
    private var locked = false
    private var pendingCancel: DispatchWorkItem?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var retryTimer: Timer?
    private var nsMonitors: [Any] = []

    func start() {
        if !startEventTap() {
            NSLog("BluejayWispr: CGEventTap unavailable (missing Accessibility?); using passive NSEvent fallback")
            startNSEventFallback()
            // Upgrade to the tap as soon as Accessibility is granted — no relaunch needed.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.startEventTap() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.nsMonitors.forEach { NSEvent.removeMonitor($0) }
                    self.nsMonitors = []
                    NSLog("BluejayWispr: Accessibility granted — upgraded to CGEventTap")
                }
            }
        }
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

    /// Start a hands-free session from the UI (pill buttons) — same as double-tapping fn.
    func beginLockedSession() {
        guard !locked, !fnIsDown else { return }
        locked = true
        onStart?()
        onLock?()
    }

    // MARK: - CGEventTap path

    private func startEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function) else {
                return Unmanaged.passUnretained(event)
            }
            handleFnChange(down: event.flags.contains(.maskSecondaryFn))
            // Swallow: macOS never sees the bare fn tap, so its own
            // emoji-picker/dictation action can't fire.
            return nil
        case .keyDown:
            if locked, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                locked = false
                onCancel?()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - NSEvent fallback (observe-only)

    private func startNSEventFallback() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            guard event.keyCode == kVK_Function else { return }
            self?.handleFnChange(down: event.modifierFlags.contains(.function))
        }) { nsMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == kVK_Escape, let self, self.locked {
                self.locked = false
                self.onCancel?()
            }
        }) { nsMonitors.append(monitor) }
    }

    // MARK: - Gesture state machine

    private func handleFnChange(down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime

        if down, !fnIsDown {
            fnIsDown = true
            fnDownAt = now
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
            onStart?()
        } else if !down, fnIsDown {
            fnIsDown = false
            if locked { return }  // release of the second tap; session stays live
            let heldFor = now - fnDownAt
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
