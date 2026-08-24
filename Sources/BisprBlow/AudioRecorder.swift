import AVFoundation
import CoreAudio

/// Mic capture via AVCaptureSession. Streams buffers to a consumer and publishes a
/// smoothed level (0...1) for the waveform UI.
///
/// **Not AVAudioEngine, and this is the whole reason the device picker works.** AVAudioEngine
/// wants one device providing both input *and* output. Point its input node at an input-only
/// microphone — which is every ordinary USB mic, and the built-in one — and the graph is handed a
/// 0ch/0Hz output format and fails to initialise with `-10868`, after which `installTap` *raises*
/// and aborts the whole app. `setDeviceID` is not the fix; nothing is, because the node latches
/// its format when it is created and never renegotiates. Measured on this machine over twelve
/// runs: through AVAudioEngine the USB PnP mic and the built-in mic both yield 0 frames, while the
/// EarPods yield audio only because they carry speakers too. Through `AVCaptureDeviceInput`, which
/// takes an arbitrary device by design, all three capture — 72192 frames from the USB mic at the
/// same ~150ms startup the engine cost. Do not "simplify" this back to AVAudioEngine.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
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

    /// Name of the device actually being recorded from — the selection if there is one, otherwise
    /// the system default. The mic flash and the no-audio notice both name this rather than the
    /// default, which is a different device whenever a selection is in force.
    static func currentInputDeviceName() -> String {
        let uid = AppSettings.shared.inputDeviceUID
        if !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) { return device.localizedName }
        return defaultInputDeviceName()
    }

    enum CaptureError: LocalizedError {
        case noDevice
        case rejected

        var errorDescription: String? {
            switch self {
            case .noDevice: "no input device available"
            case .rejected: "the input device could not be opened"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    /// Buffers arrive here, and the signal accumulators are only ever touched on it. `stop` syncs
    /// against it before reading them, which is what `removeTap` used to give us for free.
    private let queue = DispatchQueue(label: "ai.getbluejay.bisprblow.capture")
    private(set) var isRunning = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    // Signal quality for the dictation in progress. Accumulated in the tap because that is the only
    // place the samples exist — nothing downstream can recover gain or clipping from a transcript.
    private var frames = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var clipped = 0
    private var capturedFormat: AVAudioFormat?

    /// Frames captured during the dictation that just ended. Zero means the words went nowhere, and
    /// the caller must not go on to finalise a recognizer that was never fed — see `finishRecording`.
    var capturedFrames: Int { queue.sync { frames } }

    /// How long the session keeps running after a dictation ends. `startRunning()` is ~150ms of
    /// cold CoreAudio setup and was the bulk of the gap between the pill saying "recording"
    /// and the mic actually capturing (see `ActivationTrace` in `Log.swift`). Staying up across a
    /// burst of dictations skips it. Not forever, though: a running session holds the microphone,
    /// and macOS keeps its recording indicator lit for exactly as long as it does.
    private static let warmWindow: TimeInterval = 30
    private var coolDown: DispatchWorkItem?
    /// The device the warm session is configured for. A changed selection has to be rebuilt rather
    /// than record the wrong mic.
    private var warmDeviceUID: String?

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
        // Pin the delivered format rather than take the device's. `measure` and `Transcriber.feed`
        // both reach for `floatChannelData`, which is nil for anything but non-interleaved float —
        // so a device that happened to hand us int16 would read as silence, which is the one
        // failure mode this file exists to make impossible.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // The mic being yanked mid-warm, or changing format under us, arrives here. Drop the warm
        // session so the next dictation rebuilds from scratch rather than finding out the hard way.
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            logLine("audio session runtime error: \(error?.localizedDescription ?? "unknown")")
            isRunning = false
            session.stopRunning()
            warmDeviceUID = nil
        }
    }

    func start() throws {
        guard !isRunning else { return }
        coolDown?.cancel()
        coolDown = nil

        // Empty UID = follow the system default input.
        let uid = AppSettings.shared.inputDeviceUID
        guard let device = (uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid))
            ?? AVCaptureDevice.default(for: .audio)
        else { throw CaptureError.noDevice }

        if AppSettings.shared.restoreMicVolume,
           let deviceID = uid.isEmpty ? Self.defaultInputDeviceID() : Self.deviceID(forUID: uid) {
            Self.restoreInputVolume(deviceID)
        }

        if warmDeviceUID != device.uniqueID {
            session.beginConfiguration()
            for existing in session.inputs { session.removeInput(existing) }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CaptureError.rejected
            }
            session.addInput(input)
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw CaptureError.rejected
                }
                session.addOutput(output)
            }
            session.commitConfiguration()
        }

        queue.sync {
            frames = 0
            sumSquares = 0
            peak = 0
            clipped = 0
            capturedFormat = nil
        }

        // `isRunning` gates delivery, so it has to be true before the first buffer can arrive —
        // a warm session is already producing them and they are dropped on the floor until here.
        isRunning = true
        if !session.isRunning { session.startRunning() }
        warmDeviceUID = device.uniqueID
    }

    /// Ends capture but leaves the session warm — see `warmWindow`. `isRunning` is what stops audio
    /// reaching the consumer, so nothing is captured in the meantime.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Let any in-flight buffer finish before the accumulators are read.
        queue.sync {}
        logSignal()

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isRunning else { return }
            self.session.stopRunning()
            self.warmDeviceUID = nil
        }
        coolDown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmWindow, execute: work)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return }

        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        else { return }
        // Before the copy, not after: the buffer list reports its size from `frameLength`, so a
        // buffer still at zero advertises no room and the copy fails rather than filling it.
        buffer.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(count),
            into: buffer.mutableAudioBufferList) == noErr
        else { return }

        capturedFormat = format
        let level = measure(buffer)
        onBuffer?(buffer)
        onLevel?(level)
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
        guard let format = capturedFormat else { return }
        let rms = sqrt(sumSquares / Double(frames))
        let dB = { (x: Double) in x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }
        logLine("""
            audio \(Int(format.sampleRate))Hz/\(format.channelCount)ch \
            secs=\(String(format: "%.1f", Double(frames) / format.sampleRate)) \
            rms=\(dB(rms))dBFS peak=\(dB(Double(peak)))dBFS clipped=\(clipped)
            """)
    }
}
