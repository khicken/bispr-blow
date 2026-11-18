import AVFoundation
import ScreenCaptureKit

// Call notes: the mic (you) and system audio (everyone else on the call) captured as two sources, so
// who said what needs no diarization. Each source is cut at pauses and transcribed by Parakeet, and
// every line is appended to Meetings/<start>/live.ndjson, which bluejay_callpr watches.
final class NoteTaker: NSObject, SCStreamOutput {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BisprBlow/Meetings")

    private final class Segment {
        let stream = ParakeetStream()
        let start = Date()
        var seconds = 0.0, quiet = 0.0, voiced = 0.0
    }

    private let queue = DispatchQueue(label: "notetaker")
    private var stream: SCStream?
    private var file: URL?
    private var segments: [String: Segment] = [:]
    private var pending = DispatchGroup()
    private var vocabulary: (terms: [String], heardAs: [String: [String]]) = ([], [:])

    var isRunning: Bool { stream != nil }

    func start() async -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return false
        }
        await Parakeet.shared.load()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = true
            vocabulary = (AppSettings.shared.vocabulary, AppSettings.shared.heardAs)
            let uid = AppSettings.shared.inputDeviceUID
            if !uid.isEmpty { config.microphoneCaptureDeviceID = uid }
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let dir = Self.root.appendingPathComponent(Self.stamp.string(from: Date()))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            file = dir.appendingPathComponent("live.ndjson")
            FileManager.default.createFile(atPath: file!.path, contents: nil)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                                  configuration: config, delegate: nil)
            for type in [SCStreamOutputType.screen, .audio, .microphone] {
                try stream.addStreamOutput(self, type: type, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
            self.stream = stream
            logLine("notes started \(dir.lastPathComponent)")
            return true
        } catch {
            logLine("notes failed to start: \(error)")
            return false
        }
    }

    // Returns the transcript file once the last segment is written.
    func stop() async -> URL? {
        guard let stream else { return nil }
        self.stream = nil
        try? await stream.stopCapture()
        let group = queue.sync {
            for source in segments.keys { flush(source) }
            return pending
        }
        await withCheckedContinuation { done in group.notify(queue: queue) { done.resume() } }
        return file
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, var asbd = buffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let source = type == .microphone ? "mic" : "system"
        try? buffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                  let samples = pcm.floatChannelData?[0] else { return }
            let count = Int(pcm.frameLength)
            guard count > 0 else { return }
            let segment = segments[source] ?? { let s = Segment(); segments[source] = s; return s }()
            segment.stream.append(pcm)
            var energy: Float = 0
            for i in 0..<count { energy += samples[i] * samples[i] }
            let seconds = Double(count) / format.sampleRate
            segment.seconds += seconds
            // ponytail: fixed RMS gate; a per-source noise floor if quiet rooms or loud mics misfire
            if (energy / Float(count)).squareRoot() < 0.008 { segment.quiet += seconds } else {
                segment.quiet = 0
                segment.voiced += seconds
            }
            if (segment.seconds > 4 && segment.quiet > 0.7) || segment.seconds > 25 { flush(source) }
        }
    }

    // On `queue`. Silence-only segments are dropped: Parakeet invents words for them.
    private func flush(_ source: String) {
        guard let segment = segments.removeValue(forKey: source) else { return }
        guard segment.voiced > 0.3, let file else {
            Task { await segment.stream.cancel() }
            return
        }
        pending.enter()
        Task {
            defer { pending.leave() }
            guard let audio = await segment.stream.finish() else { return }
            guard let text = await Parakeet.shared.transcribe(audio.audio, ctc: audio.ctc, vocabulary: vocabulary.terms,
                                                               heardAs: vocabulary.heardAs)?.text,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let row: [String: Any] = ["text": text, "speaker": ["source": source, "id": 0],
                                      "startEpochMs": Int(segment.start.timeIntervalSince1970 * 1000)]
            guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
            line.append(0x0A)
            queue.sync {
                guard let handle = try? FileHandle(forWritingTo: file) else { return }
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}
