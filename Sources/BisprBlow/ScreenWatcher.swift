import AppKit
import ApplicationServices

// Keeps a warm snapshot of the front app so a command does not wait on a screen read. Notifications
// only mark it stale: reading on every one would load the target app's main thread for nothing.
@MainActor final class ScreenWatcher {
    static let shared = ScreenWatcher()
    static let maxAge: TimeInterval = 5
    static let prefetchAge: TimeInterval = 1

    private static let watchedNotifications = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXFocusedUIElementChangedNotification,
    ]

    private var cached: ScreenSnapshot?
    // Bumped on every invalidation, so a read that started before a change cannot clear it.
    private var generation = 0
    private var isStale = true
    private var reading: Task<ScreenSnapshot?, Never>?
    private var observer: AXObserver?
    // Title changes are watched on the front window alone: on the app they fire for every tab title and badge count.
    private var titledWindow: AXUIElement?
    private var activationToken: NSObjectProtocol?

    func start() {
        guard activationToken == nil else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenWatcher.shared.observeFrontApp() }
        }
        observeFrontApp()
    }

    func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        removeObserver()
        cached = nil
        invalidate()
    }

    func invalidate() {
        generation += 1
        isStale = true
    }

    // After Jay acts, a read already under way shows the screen from before.
    func invalidateWithReads() {
        invalidate()
        reading = nil
    }

    func prefetch() {
        guard reading == nil, let front = NSWorkspace.shared.frontmostApplication else { return }
        if let cached, isFresh(cached, pid: front.processIdentifier, maxAge: Self.prefetchAge) { return }
        read()
    }

    func snapshot() async -> ScreenSnapshot? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        if let cached, isFresh(cached, pid: pid, maxAge: Self.maxAge) { return cached }
        // A read in flight started after the user began speaking, so it is as fresh as the command.
        if let reading, let snapshot = await reading.value, snapshot.pid == pid { return snapshot }
        return await read().value
    }

    private func isFresh(_ snapshot: ScreenSnapshot, pid: pid_t, maxAge: TimeInterval) -> Bool {
        !isStale && snapshot.pid == pid && Date().timeIntervalSince(snapshot.takenAt) < maxAge
    }

    @discardableResult
    private func read() -> Task<ScreenSnapshot?, Never> {
        let startedAt = generation
        let task = Task<ScreenSnapshot?, Never> {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return await ScreenElements.snapshot(app: app)
        }
        reading = task
        Task {
            let snapshot = await task.value
            if reading == task { reading = nil }
            guard let snapshot else { return }
            cached = snapshot
            isStale = generation != startedAt
        }
        return task
    }

    private func observeFrontApp() {
        removeObserver()
        invalidate()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            MainActor.assumeIsolated { ScreenWatcher.shared.noteChange(notification as String, on: element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, ScreenElements.messagingTimeout)
        for name in Self.watchedNotifications {
            AXObserverAddNotification(created, root, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        watchTitle(of: ScreenElements.attribute(root, kAXFocusedWindowAttribute))
    }

    private func noteChange(_ notification: String, on element: AXUIElement) {
        invalidate()
        if notification == kAXFocusedWindowChangedNotification { watchTitle(of: element) }
    }

    private func watchTitle(of window: AXUIElement?) {
        guard let observer else { return }
        if let titledWindow { AXObserverRemoveNotification(observer, titledWindow, kAXTitleChangedNotification as CFString) }
        titledWindow = window
        guard let window else { return }
        AXUIElementSetMessagingTimeout(window, ScreenElements.messagingTimeout)
        AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, nil)
    }

    private func removeObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        titledWindow = nil
    }
}
