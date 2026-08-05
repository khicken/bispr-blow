import AVFoundation
import CoreAudio

/// Mic capture via AVAudioEngine. Streams buffers to a consumer and publishes a
/// smoothed level (0...1) for the waveform UI.
final class AudioRecorder {
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0
        else { return nil }
        return deviceID
    }

    /// Name of the system default input device (e.g. "MacBook Pro Microphone").
    static func defaultInputDeviceName() -> String {
        guard let deviceID = defaultInputDeviceID() else { return "" }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let name
        else { return "" }
        return name.takeRetainedValue() as String
    }
    /// Selectable input devices. `uid` is the Core Audio device UID (also AVCaptureDevice.uniqueID).
    static func inputDevices() -> [(uid: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Core Audio device for a UID, so the engine can be pointed at a non-default mic.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Some apps — video calls, most often — turn the system input volume down and never put it
    /// back, and a quiet capture comes back as confident wrong words (measured here: 14/100 gain,
    /// -40 to -63 dBFS dictations). Behind `AppSettings.restoreMicVolume`, off by default. Only
    /// ever raises, so a deliberately loud mic is left alone.
    private static func restoreInputVolume(_ deviceID: AudioDeviceID) {
        // ponytail: fixed 75% floor, the level the user confirmed; make it a slider if asked.
        let floor: Float32 = 0.75
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr,
                  volume < floor else { continue }
            var raised = floor
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &raised) == noErr {
                logLine("audio input volume raised \(Int(volume * 100))% → \(Int(raised * 100))%")
            }
        }
    }

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    // Signal quality for the dictation in progress. Accumulated in the tap because that is the only
    // place the samples exist — nothing downstream can recover gain or clipping from a transcript.
    private var frames = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var clipped = 0

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode

        // Empty UID = follow the system default input.
        let uid = AppSettings.shared.inputDeviceUID
        let deviceID = uid.isEmpty ? Self.defaultInputDeviceID() : Self.deviceID(forUID: uid)
        if !uid.isEmpty, let deviceID {
            try? input.auAudioUnit.setDeviceID(deviceID)
        }
        if AppSettings.shared.restoreMicVolume, let deviceID {
            Self.restoreInputVolume(deviceID)
        }

        frames = 0
        sumSquares = 0
        peak = 0
        clipped = 0

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            self.onLevel?(self.measure(buffer))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        logSignal()
    }

    /// RMS level for the waveform, folded together with the per-dictation quality accumulators so
    /// the samples are walked once.
    private func measure(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var localPeak: Float = 0
        var localClipped = 0
        for i in 0..<n {
            let s = data[i]
            sum += s * s
            let mag = abs(s)
            if mag > localPeak { localPeak = mag }
            if mag >= 0.999 { localClipped += 1 }
        }
        frames += n
        sumSquares += Double(sum)
        if localPeak > peak { peak = localPeak }
        clipped += localClipped

        let rms = sqrt(sum / Float(n))
        // Map typical speech RMS (~0.005–0.2) onto 0...1; steeper curve = livelier bars.
        return min(1, max(0, pow(rms * 26, 0.6)))
    }

    /// One line per dictation. A weak or clipped signal does not come back as silence — it comes back
    /// as confident wrong words, so it is indistinguishable from a model problem without this. dBFS
    /// because that is the unit the numbers are judged in: speech wants roughly -30 to -12 dBFS mean,
    /// and under about -45 is a gain problem no amount of model or prompt work will fix.
    private func logSignal() {
        guard frames > 0 else {
            logLine("audio no frames captured")
            return
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        let rms = sqrt(sumSquares / Double(frames))
        let dB = { (x: Double) in x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }
        logLine("""
            audio \(Int(format.sampleRate))Hz/\(format.channelCount)ch \
            secs=\(String(format: "%.1f", Double(frames) / format.sampleRate)) \
            rms=\(dB(rms))dBFS peak=\(dB(Double(peak)))dBFS clipped=\(clipped)
            """)
    }
}
