import Foundation

// Manages the system "Press 🌐 key to…" action (com.apple.HIToolbox AppleFnUsageType: 0 = Do
// Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation). The CGEventTap
// swallow is not always enough — the Globe-key action can fire below the tap — so while the app runs
// we set the action to Do Nothing and restore the user's value on quit.
enum SystemFnKey {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    private static let savedKey = "savedFnUsageType"  // our own defaults; -1 = key was unset

    static func currentUsage() -> Int? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    }

    // Suppress only while fn is actually bound to something: an app that took over the Globe
    // key without using it is just a bug report waiting to happen.
    static func sync(suppress: Bool) {
        suppress ? suppressWhileRunning() : restore()
    }

    // Remember the user's setting and switch to Do Nothing.
    private static func suppressWhileRunning() {
        let current = currentUsage()
        guard current != 0 else { return }  // already Do Nothing; nothing to save or restore
        UserDefaults.standard.set(current ?? -1, forKey: savedKey)
        write(0)
    }

    // Call on quit: put the user's original setting back (only if we changed it).
    static func restore() {
        guard UserDefaults.standard.object(forKey: savedKey) != nil else { return }
        let saved = UserDefaults.standard.integer(forKey: savedKey)
        write(saved == -1 ? nil : saved)
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetValue(key, value as CFNumber?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Nudge running apps to re-read the HIToolbox prefs.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleKeyboardPreferencesChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
