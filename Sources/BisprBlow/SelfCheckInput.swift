import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

extension SelfCheck {
    // Where a release lands the pill. Screen coordinates, bottom-left origin, against a
    // `visibleFrame`-shaped rect.
    static func checkAnchors() {
        let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
        let pill = CGSize(width: 122, height: 48)
        typealias Anchor = RecordingPillController.Anchor
        precondition(Anchor.containing(NSPoint(x: 60, y: 440), in: screen) == .leftCentre)
        precondition(Anchor.containing(NSPoint(x: 1300, y: 440), in: screen) == .rightCentre)
        precondition(Anchor.containing(NSPoint(x: 676, y: 20), in: screen) == .bottomCentre)
        // Released in open space: nil, so the pill stays where it was instead of being flung to
        // whichever target happened to be closest.
        precondition(Anchor.containing(NSPoint(x: 676, y: 440), in: screen) == nil)
        // The lit target is the landing spot, so a point inside a zone must be near its landing.
        precondition(Anchor.leftCentre.zone(in: screen)
            .contains(NSPoint(x: 60, y: 440)))
        precondition(Anchor.leftCentre.landing(in: screen).size == CGSize(width: 48, height: 122))
        precondition(Anchor.leftCentre.origin(size: pill, in: screen) == NSPoint(x: 4, y: 415))
        precondition(Anchor.rightCentre.origin(size: pill, in: screen) == NSPoint(x: 1226, y: 415))
        precondition(Anchor.bottomCentre.origin(size: pill, in: screen) == NSPoint(x: 615, y: 0))
        // The bar hugs its panel's edge, and `rotation` maps that local edge onto the parked screen
        // edge. Out of step and the sliver drifts to the middle of the panel, or to the wrong side.
        precondition(Anchor.bottomCentre.contentAlignment == .bottom)
        precondition(Anchor.leftCentre.contentAlignment == .top
                     && Anchor.rightCentre.contentAlignment == .top)
        // A side-anchored pill is the same bar turned 90°, so its panel is the transpose. If these
        // ever disagree the panel clips the pill or claims mouse events beside it.
        let flat = PillView.size(for: .idle, anchor: .bottomCentre)
        precondition(PillView.size(for: .idle, anchor: .leftCentre)
            == CGSize(width: flat.height, height: flat.width))
        precondition(Anchor.leftCentre.isVertical && !Anchor.bottomCentre.isVertical)
        // The hit region sits on the capsule that is drawn, not on the panel: the idle panel is
        // permanently hover-sized, so a region matching it opens the pill from a pointer nowhere near
        // it. Idle box 110x36 (panel minus margin), resting sliver 42x9 against `contentAlignment`.
        let box = CGRect(x: 0, y: 0, width: 110, height: 36)
        let resting = PillHitRegion(size: CGSize(width: 42, height: 9), alignment: .bottom)
            .path(in: box).boundingRect
        precondition(resting.maxY == box.maxY && abs(resting.midX - box.midX) < 0.01)
        precondition(resting.height == 9 && resting.width == 42)
        // Hovering grows it to the whole box, and only grows it — the pointer that opened the pill
        // is still inside, which is what keeps it from flapping open and shut.
        let hovered = PillHitRegion(size: box.size, alignment: .bottom).path(in: box).boundingRect
        precondition(hovered.contains(CGPoint(x: resting.midX, y: resting.midY)))
        // A side anchor parks against the local top edge, in the pill's own unrotated space.
        let side = PillHitRegion(size: CGSize(width: 42, height: 9), alignment: .top)
            .path(in: box).boundingRect
        precondition(side.minY == box.minY)
    }

    // Bindings are serialized into UserDefaults and rendered as key caps in Settings, so a break
    // here either loses the user's shortcut or shows them the wrong one.
    static func checkShortcuts() {
        let combo = Shortcut(trigger: .key(kVK_ANSI_D),
                             flags: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        let mouse4 = Shortcut(trigger: .mouse(3))

        precondition(Shortcut.fn.display == "fn")
        precondition(Shortcut.escape.display == "esc")
        precondition(combo.display == "⌃⌥D")
        precondition(mouse4.display == "Mouse 4")  // button 3 is what every UI calls mouse 4
        precondition(Shortcut(trigger: .key(kVK_Space)).display == "Space")

        // Modifiers have to match exactly, minus the noise bits macOS adds.
        precondition(combo.matches(keyCode: kVK_ANSI_D,
                                   flags: [.maskControl, .maskAlternate, .maskNonCoalesced]))
        precondition(!combo.matches(keyCode: kVK_ANSI_D, flags: [.maskControl]))
        precondition(!combo.matches(keyCode: kVK_ANSI_D, flags: [.maskControl, .maskAlternate, .maskShift]))
        precondition(!combo.matches(keyCode: kVK_ANSI_F, flags: [.maskControl, .maskAlternate]))
        // A standalone modifier matches on its keycode whatever else is held — that is what
        // makes "hold fn" work while shift is down, and it is what the fn-only monitor did.
        precondition(Shortcut.fn.matches(keyCode: kVK_Function, flags: [.maskSecondaryFn, .maskShift]))
        precondition(!Shortcut.fn.matches(keyCode: kVK_Shift, flags: [.maskSecondaryFn]))
        precondition(mouse4.matches(mouseButton: 3) && !mouse4.matches(mouseButton: 2))
        // Only an fn binding may take over the macOS Globe key.
        precondition(Shortcut.fn.usesFn && !combo.usesFn)
        precondition(Shortcut(trigger: .key(kVK_ANSI_D),
                              flags: CGEventFlags.maskSecondaryFn.rawValue).usesFn)

        // Recording a binding: hold the combination, let go, and what was down is what is saved. Both
        // halves are from real reports — ⌃⇧G recorded as ⇧G, and ⌃⇧ not recording at all. The flags on
        // these keyDowns are deliberately wrong, because that is the bug: the recorder swallows each
        // modifier's flagsChanged, so the flags stamped on the following keyDown are missing the
        // modifier that was held first.
        func record(_ steps: [(CGEventType, Int?, CGEventFlags)]) -> Shortcut? {
            var state = ShortcutMonitor.CaptureState()
            for (type, code, flags) in steps {
                if case .record(let shortcut) = ShortcutMonitor.captureStep(
                    type: type, keyCode: code, mouseButton: nil, flags: flags, state: &state) {
                    return shortcut
                }
            }
            return nil
        }
        // ⌃⇧G, with the keyDown carrying only shift, then everything released.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.keyDown, kVK_ANSI_G, [.maskShift]),
                             (.keyUp, kVK_ANSI_G, [.maskShift]),
                             (.flagsChanged, kVK_Shift, [.maskControl]),
                             (.flagsChanged, kVK_Control, [])])?.display == "⌃⇧G")
        // Nothing is recorded until the last key is up: the same sequence, stopped early.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.keyDown, kVK_ANSI_G, [.maskShift]),
                             (.keyUp, kVK_ANSI_G, [.maskShift])]) == nil)
        // Modifiers with no key is a binding in its own right — hold ⌃⇧ to talk. It has no keycode,
        // so it can only be recorded on release, hence release-to-finalize rather than first-key-wins.
        precondition(record([(.flagsChanged, kVK_Control, [.maskControl]),
                             (.flagsChanged, kVK_Shift, [.maskControl, .maskShift]),
                             (.flagsChanged, kVK_Shift, [.maskControl]),
                             (.flagsChanged, kVK_Control, [])])?.display == "⌃⇧")
        // A lone modifier stays a keycode, so left ⌃ and right ⌃ remain different bindings.
        precondition(record([(.flagsChanged, kVK_Function, [.maskSecondaryFn]),
                             (.flagsChanged, kVK_Function, [])]) == Shortcut.fn)
        precondition(record([(.flagsChanged, kVK_RightControl, [.maskControl]),
                             (.flagsChanged, kVK_RightControl, [])])?.display == "Right ⌃")
        // A plain key with no modifiers at all.
        precondition(record([(.keyDown, kVK_ANSI_G, []), (.keyUp, kVK_ANSI_G, [])])?.display == "G")

        // A modifiers-only binding fires when its set completes and stops when it breaks — the
        // set is the whole gesture, so it matches exactly rather than as a subset.
        let ctrlShift = Shortcut(trigger: .modifiers,
                                 flags: CGEventFlags([.maskControl, .maskShift]).rawValue)
        precondition(ctrlShift.matches(modifiers: [.maskControl, .maskShift]))
        precondition(!ctrlShift.matches(modifiers: [.maskControl]))
        precondition(!ctrlShift.matches(modifiers: [.maskControl, .maskShift, .maskCommand]))
        precondition(!ctrlShift.matches(modifiers: []))
        // It carries no keycode, so the key path must never claim it as well.
        precondition(!ctrlShift.matches(keyCode: kVK_Control, flags: [.maskControl, .maskShift]))
        precondition(Shortcut(trigger: .modifiers,
                              flags: CGEventFlags([.maskSecondaryFn, .maskShift]).rawValue).usesFn)

        // Round trip: bindings live in UserDefaults as JSON.
        let saved = ["pushToTalk": [Shortcut.fn, combo], "handsFree": [mouse4]]
        let data = try! JSONEncoder().encode(saved)
        precondition(try! JSONDecoder().decode([String: [Shortcut]].self, from: data) == saved)

        // fn stays the shipped push-to-talk default; Esc stays cancel.
        precondition(ShortcutAction.pushToTalk.defaults == [.fn])
        precondition(ShortcutAction.cancel.defaults == [.escape])

        // Assigning a binding steals it: two actions on one key means one never fires.
        let stolen = AppSettings.adding(mouse4, to: .cancel, in: saved)
        precondition(stolen["handsFree"] == [])
        precondition(stolen["cancel"] == [mouse4])
        precondition(stolen["pushToTalk"] == [.fn, combo])
        // Re-adding the same binding to the same action must not duplicate it.
        precondition(AppSettings.adding(.fn, to: .pushToTalk, in: saved)["pushToTalk"] == [combo, .fn])
    }

    // The hold-versus-double-tap machine, on real timings, so this costs about a second. Every branch
    // here either drops a dictation or starts one nobody asked for, and none of it can be exercised
    // without physically pressing a key.
    static func checkGestures() {
        // Hold past the threshold: start on press, insert on release.
        run { monitor, log in
            precondition(monitor.simulate(.pushToTalk, down: true))
            pump(0.32)
            precondition(monitor.simulate(.pushToTalk, down: false))
            precondition(log() == ["start", "stop"], "\(log())")
        }

        // Short tap on its own: the session started, so it has to be thrown away — but only
        // after the double-tap window has passed with no second tap.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            precondition(log() == ["start"], "\(log())")
            pump(0.45)
            precondition(log() == ["start", "cancel"], "\(log())")
        }

        // Double tap locks hands-free, and cancels the discard the first tap queued up.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pushToTalk, down: false)
            pump(0.45)
            precondition(log() == ["start", "lock"], "\(log())")
            // A tap while locked finishes the session.
            _ = monitor.simulate(.pushToTalk, down: true)
            precondition(log() == ["start", "lock", "stop-locked"], "\(log())")
        }

        // "Dictate and send" is push to talk that asks for a Return afterwards.
        run { monitor, log in
            _ = monitor.simulate(.pressEnter, down: true)
            pump(0.32)
            _ = monitor.simulate(.pressEnter, down: false)
            precondition(log() == ["start+enter", "stop"], "\(log())")
        }

        // Releasing a different binding must not end someone else's hold.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            _ = monitor.simulate(.pressEnter, down: false)
            pump(0.32)
            precondition(log() == ["start"], "\(log())")
            _ = monitor.simulate(.pushToTalk, down: false)
            precondition(log() == ["start", "stop"], "\(log())")
        }

        // Cancelling mid-hold discards it, and the trigger's own release is then a no-op
        // rather than a second stop that would insert the text anyway.
        run { monitor, log in
            _ = monitor.simulate(.pushToTalk, down: true)
            precondition(monitor.simulate(.cancel, down: true))
            _ = monitor.simulate(.cancel, down: false)
            _ = monitor.simulate(.pushToTalk, down: false)
            pump(0.45)
            precondition(log() == ["start", "cancel"], "\(log())")
        }

        // Nothing to cancel: Esc has to reach the app the user is actually typing in.
        run { monitor, log in
            precondition(!monitor.simulate(.cancel, down: true))
            precondition(!monitor.simulate(.cancel, down: false))
            precondition(log().isEmpty)
        }

        // Hands-free binding: press to start, press again to finish.
        run { monitor, log in
            _ = monitor.simulate(.handsFree, down: true)
            precondition(log() == ["start", "lock"], "\(log())")
            _ = monitor.simulate(.handsFree, down: true)
            precondition(log() == ["start", "lock", "stop-locked"], "\(log())")
        }
    }

    // A fresh monitor per scenario — no event tap, no shared state carried over.
    static func run(_ body: (ShortcutMonitor, () -> [String]) -> Void) {
        let monitor = ShortcutMonitor()
        var log: [String] = []
        monitor.onStart = { log.append($0 ? "start+enter" : "start") }
        monitor.onStop = { log.append($0 ? "stop-locked" : "stop") }
        monitor.onCancel = { log.append("cancel") }
        monitor.onLock = { log.append("lock") }
        body(monitor, { log })
    }

    // Let the run loop turn so the deferred discard actually fires.
    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
