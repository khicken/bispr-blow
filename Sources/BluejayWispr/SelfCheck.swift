import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// `BluejayWispr --self-check`: asserts the text logic that silently loses user words if
/// it breaks. `precondition`, not `assert` — release builds strip asserts.
enum SelfCheck {
    static func run() {
        let raw = "okay so um i tested the new build and uh the login flow it's mostly working "
            + "but i found like two issues one is the spinner never goes away and two um when "
            + "you log out it doesn't clear the session so we should fix those before friday"

        // Trailing off, or coming back half-length, means content was dropped.
        precondition(LLMCleaner.looksTruncated("We should update the prompt and tailor...", raw: raw))
        precondition(LLMCleaner.looksTruncated("I tested the new build and found two issues.", raw: raw))
        // Elision mid-sentence, on a short dictation — "what's in this PR?" became "...".
        precondition(LLMCleaner.looksTruncated(
            "Yeah, wait... Can you see the link again?",
            raw: "Yeah, wait, what's in this PR? Can you see the link again?"))
        // An ellipsis the speaker actually dictated is not the model's doing.
        precondition(!LLMCleaner.looksTruncated("Wait... never mind.", raw: "wait ... never mind"))
        // A leaked reasoning trace, or the model answering instead of cleaning, runs long.
        precondition(LLMCleaner.looksTruncated(
            "Okay, let me tackle this. The user is dictating in Slack and wants the transcript "
            + "cleaned. First I should check for filler words, then apply the style rules for "
            + "chat, then make sure the question is preserved rather than answered.",
            raw: "yeah wait what's in this PR"))
        precondition(!LLMCleaner.looksTruncated(
            "I tested the new build and the login flow is mostly working, but I found two issues. "
            + "First, the spinner never goes away. Second, when you log out it doesn't clear the "
            + "session. We should fix those before Friday.", raw: raw))
        // Short dictations legitimately shrink a lot.
        precondition(!LLMCleaner.looksTruncated("Does it work?", raw: "um does it uh does it work"))

        precondition(LLMCleaner.ruleClean("um the the tests uh pass") == "The tests pass")
        precondition(LLMCleaner.sanitize("```\nhello\n```", fallback: "x") == "hello")
        precondition(LLMCleaner.sanitize("", fallback: "fallback") == "fallback")

        let settings = AppSettings.shared
        let before = settings.dictionary
        settings.addDictionaryWords(["  worktree ", "Kubernetes", "worktree", ""])
        precondition(settings.dictionary.filter { $0 == "worktree" }.count == 1)
        precondition(settings.dictionary.contains("Kubernetes"))
        settings.dictionary = before

        // A section left out of a sidebar group just disappears from the nav, silently.
        precondition(DashboardView.Section.groups.flatMap(\.items) == DashboardView.Section.allCases)

        checkAnchors()
        checkShortcuts()
        checkGestures()

        print("self-check passed")
    }

    /// Dropping the pill snaps it to the nearest anchor. Snapping on x alone made a vertical drag
    /// teleport back to the bottom of the screen, so both axes count.
    private static func checkAnchors() {
        let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
        let pill = CGSize(width: 122, height: 48)
        typealias Anchor = RecordingPillController.Anchor
        // Dropped near the left edge halfway up: the left anchor, not the bottom one.
        precondition(Anchor.nearest(to: NSPoint(x: 60, y: 500), size: pill, in: screen) == .leftCentre)
        precondition(Anchor.nearest(to: NSPoint(x: 1300, y: 500), size: pill, in: screen) == .rightCentre)
        precondition(Anchor.nearest(to: NSPoint(x: 676, y: 30), size: pill, in: screen) == .bottomCentre)
        // Dropped low but hard left still belongs on the left edge.
        precondition(Anchor.nearest(to: NSPoint(x: 40, y: 300), size: pill, in: screen) == .leftCentre)
        precondition(Anchor.leftCentre.origin(size: pill, in: screen) == NSPoint(x: 12, y: 415))
        precondition(Anchor.rightCentre.origin(size: pill, in: screen) == NSPoint(x: 1218, y: 415))
        precondition(Anchor.bottomCentre.origin(size: pill, in: screen) == NSPoint(x: 615, y: 0))
        // A side-anchored pill is the same bar turned 90°, so its panel is the transpose. If these
        // ever disagree the panel clips the pill or claims mouse events beside it.
        let flat = PillView.size(for: .idle, anchor: .bottomCentre)
        precondition(PillView.size(for: .idle, anchor: .leftCentre)
            == CGSize(width: flat.height, height: flat.width))
        precondition(Anchor.leftCentre.isVertical && !Anchor.bottomCentre.isVertical)
    }

    /// Bindings are serialized into UserDefaults and rendered as key caps in Settings, so a
    /// break here either loses the user's shortcut or shows them the wrong one.
    private static func checkShortcuts() {
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

    /// The hold-versus-double-tap machine. Real timings, so this costs about a second — worth it,
    /// because every branch here either drops a dictation or starts one nobody asked for, and
    /// none of it can be exercised without physically pressing a key.
    private static func checkGestures() {
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

    /// A fresh monitor per scenario — no event tap, no shared state carried over.
    private static func run(_ body: (ShortcutMonitor, () -> [String]) -> Void) {
        let monitor = ShortcutMonitor()
        var log: [String] = []
        monitor.onStart = { log.append($0 ? "start+enter" : "start") }
        monitor.onStop = { log.append($0 ? "stop-locked" : "stop") }
        monitor.onCancel = { log.append("cancel") }
        monitor.onLock = { log.append("lock") }
        body(monitor, { log })
    }

    /// Let the run loop turn so the deferred discard actually fires.
    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
