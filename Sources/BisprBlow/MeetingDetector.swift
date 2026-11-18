import AppKit
import CoreAudio

// Which meeting app, if any, is using the microphone right now. CoreAudio lists every process with
// its input state, so this sees Zoom, Teams, Meet in a browser and the like without Accessibility.
// ponytail: bundle-id allowlist, a browser on the mic counts as a meeting; add a window-title check if
// dictation sites in Chrome false-trigger.
enum MeetingDetector {
    private static let apps = ["us.zoom.xos", "com.microsoft.teams", "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
                               "com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari",
                               "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac", "com.cisco.webexmeetingsapp",
                               "com.hnc.Discord"]

    static func active() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == 0 else { return nil }
        for id in ids where read(id, kAudioProcessPropertyIsRunningInput) as UInt32? == 1 {
            guard let bundle = readBundle(id), apps.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) else { continue }
            return bundle
        }
        return nil
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? where T: FixedWidthInteger {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == 0 ? value : nil
    }

    private static func readBundle(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
