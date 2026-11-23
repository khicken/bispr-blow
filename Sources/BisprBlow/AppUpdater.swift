import AppKit
import Sparkle

// Sparkle auto-updates. The feed is appcast.xml on the latest GitHub release, which dmg.sh
// writes and signs with the EdDSA key. Sparkle checks once a day, downloads in the background,
// and installs on quit. The Settings switch "checkForUpdates" turns the daily check off.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var started = false

    // A bare `swift build` binary has no bundle, so it has no feed and no key to check against.
    var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard isAvailable, !started else { return }
        started = true
        controller.startUpdater()
        applySettings()
    }

    func applySettings() {
        guard started else { return }
        let on = AppSettings.shared.checkForUpdates
        controller.updater.automaticallyChecksForUpdates = on
        controller.updater.automaticallyDownloadsUpdates = on
    }

    // The menu item and the dashboard banner. Sparkle shows its own window from here.
    func checkForUpdates() {
        guard started else {
            NSWorkspace.shared.open(UpdateChecker.releasePage)
            return
        }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // Lets a local test point one install at another feed:
    // defaults write ai.getbluejay.bisprblow updateFeedOverride http://127.0.0.1:8000/appcast.xml
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedOverride")
    }
}
