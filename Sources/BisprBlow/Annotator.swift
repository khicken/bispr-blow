import AppKit
import AVFoundation
import NaturalLanguage
import ScreenCaptureKit

// The pill's annotate mode. While it is on, a dictation becomes a note paired with the screenshots
// taken while it was spoken, and finishing turns the session into markdown an agent can read.
// The screen is also recorded to a small video, but an agent cannot watch one, so a sentence about
// motion ("make this animation flowier") becomes a filmstrip: one image of frames from the seconds
// it was said. Everything else stays stills.
@MainActor
final class Annotator {
    // A click or a pointer resting on something is a point of interest, kept over plain ticks.
    enum Kind { case tick, hover, click }
    struct Frame {
        let t: Date; let jpeg: Data; let mouse: CGPoint; let print: [UInt8]; var kind = Kind.tick
        // What the pointer is on (`button "Mute (m)"`) and the app and window it is in, from Accessibility.
        var element = "", place = ""
    }
    struct Note { let t: Date; let end: Date; let text: String; let place: String; let frames: [Frame] }

    private var started = Date()
    private var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    private var frames: [Frame] = []
    private var notes: [Note] = []
    private var timer: Timer?
    private var busy = false
    private var stream: SCStream?
    private var recording: RecordingDone?
    private var videoStart = Date()
    private var clicks: Any?
    private var lastMouse = CGPoint.zero
    private var lastMove = Date()
    private var hoverTaken = true

    // False when Screen Recording is not granted yet; asking is what adds BisprBlow to that list.
    func start() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return false
        }
        started = Date()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BisprBlow/Annotations/\(stamp.string(from: started))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        frames = []
        notes = []
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in await self.tick() }
        }
        lastMove = Date()
        clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                self.lastMove = Date()
                // ponytail: grabbed ~100ms after the click, so it can show the click's result; a rolling
                // pre-click buffer if the moment before matters.
                if self.timer != nil, var f = await Self.grab() {
                    f.kind = .click
                    self.keep(f)
                }
            }
        }
        Task { await startVideo() }
        return true
    }

    func add(_ text: String, from start: Date, to end: Date, place: String) {
        // One every ~8s of speech, so a long walkthrough keeps its screens without becoming a recording.
        let cap = min(12, max(4, Int(end.timeIntervalSince(start) / 8)))
        notes.append(Note(t: start, end: end, text: text, place: place,
                          frames: Self.pick(frames, from: start, to: end, cap: cap)))
    }

    // The markdown, or nil when nothing was said.
    func finish(cleaner: LLMCleaner) async -> String? {
        timer?.invalidate()
        timer = nil
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        let video = await stopVideo()
        defer { frames = [] }
        guard !notes.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        var md = """
            Here is what I said while walking through my screen. Under it are the screenshots taken \
            while I said it, each marked with how far into the recording it was taken, so match them \
            to the words by position. Each screenshot is the part of the screen around my mouse pointer, \
            and the red ring is the pointer, so it marks what I was pointing at. When known, the line \
            also names the thing under the pointer and the window it is in. "clicked" marks a screenshot taken as I clicked, and "hovered" one where I rested \
            the pointer on something, so those are what I was paying attention to. A filmstrip is the moment I talked about motion: its frames are a few seconds \
            of screen recording, read left to right, then top to bottom. Open every image before \
            acting on any of it.

            """
        var n = 0
        var strips = 0
        for note in notes {
            md += "\n[\(clock(note.t))] \(note.place)\n> \(note.text)\n"
            for f in note.frames {
                n += 1
                let file = dir.appendingPathComponent(String(format: "%02d.jpg", n))
                try? f.jpeg.write(to: file)
                let why = [Kind.click: "clicked", .hover: "hovered", .tick: ""][f.kind]!
                let on = [why, f.element.isEmpty ? "" : "on \(f.element)",
                          f.place.isEmpty || f.place == note.place ? "" : "in \(f.place)"].filter { !$0.isEmpty }
                md += "- [\(clock(f.t, from: note.t))]\(on.isEmpty ? "" : " " + on.joined(separator: " ") + ":") \(file.path)\n"
            }
            guard let video else { continue }
            let sentences = Self.sentences(note.text)
            let duration = note.end.timeIntervalSince(note.t)
            for (sentence, motion) in zip(sentences, await Self.motion(sentences.map(\.text), cleaner: cleaner)) where motion {
                // Words arrive only after the recording stops, so a sentence is placed by where it
                // sits in the transcript: a third of the way through the words, a third of the way in.
                let said = note.t.addingTimeInterval(duration * sentence.mid)
                strips += 1
                let file = dir.appendingPathComponent("motion-\(strips).jpg")
                let pointer = frames.min { abs($0.t.timeIntervalSince(said)) < abs($1.t.timeIntervalSince(said)) }?.mouse
                if await Self.filmstrip(video, around: said.timeIntervalSince(videoStart), pointer: pointer, to: file) {
                    md += "- filmstrip for \"\(sentence.text)\", around [\(clock(said, from: note.t))]: \(file.path)\n"
                }
            }
        }
        if let video {
            // The filmstrips carry what mattered; a minutes-long video is too big to hand an agent.
            try? FileManager.default.removeItem(at: video)
        }
        return md
    }

    private func clock(_ t: Date, from origin: Date? = nil) -> String {
        let s = max(0, Int(t.timeIntervalSince(origin ?? started)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    // A screenshot changes or the pointer moves far enough to be pointing at something else.
    nonisolated static func differs(_ a: Frame, _ b: Frame) -> Bool {
        hypot(a.mouse.x - b.mouse.x, a.mouse.y - b.mouse.y) > 80
            || zip(a.print, b.print).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } > 3000
    }

    // Frames are only kept when they differ, so the screen at `start` is the last frame before it.
    // Clicks first, then hovers, then plain ticks spread evenly over what is left.
    nonisolated static func pick(_ frames: [Frame], from start: Date, to end: Date, cap: Int = 4) -> [Frame] {
        let before = frames.last { $0.t <= start }
        let kept = (before.map { [$0] } ?? []) + frames.filter { $0.t > start && $0.t <= end.addingTimeInterval(0.5) }
        guard kept.count > cap else { return kept }
        let interest = Array((kept.filter { $0.kind == .click } + kept.filter { $0.kind == .hover }).prefix(cap))
        let ticks = kept.filter { $0.kind == .tick }, room = cap - interest.count
        let spread = room <= 0 || ticks.isEmpty ? [] : room == 1 ? [ticks[0]]
            : (0..<min(room, ticks.count)).map { ticks[$0 * (ticks.count - 1) / max(1, min(room, ticks.count) - 1)] }
        return (interest + spread).sorted { $0.t < $1.t }
    }

    // Each sentence and the fraction of the way through the transcript its middle sits.
    nonisolated static func sentences(_ text: String) -> [(text: String, mid: Double)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let total = Double(max(1, text.count))
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { range in
            let start = Double(text.distance(from: text.startIndex, to: range.lowerBound))
            return (text[range].trimmingCharacters(in: .whitespacesAndNewlines),
                    (start + Double(text[range].count) / 2) / total)
        }
    }

    // The local model cleanup already runs (Qwen, open weights) decides which sentences are about
    // motion; without one, or when it answers off-script, a word list does.
    nonisolated static func motion(_ sentences: [String], cleaner: LLMCleaner) async -> [Bool] {
        var verdicts: [Bool] = []
        for sentence in sentences {
            let answer = await cleaner.ask(system: """
                Someone recording their screen is giving feedback on an app. Reply "yes" if the sentence \
                is about motion: an animation, a transition, scrolling, loading, timing, or how something \
                moves or feels while used. Reply "no" if it is about how something looks or what it says \
                at one moment, or is not about the screen. Reply with one word.
                """, sentence)?.lowercased()
            guard let answer, answer.contains("yes") != answer.contains("no") else {
                return sentences.map(keywordMotion)
            }
            verdicts.append(answer.contains("yes"))
        }
        return verdicts
    }

    nonisolated static func keywordMotion(_ sentence: String) -> Bool {
        sentence.range(of: #"\b(animat\w*|transition\w*|flow(y|ier)?|smooth\w*|jank\w*|lag\w*|stutter\w*|flicker\w*|scroll\w*|hover\w*|fade\w*|slide\w*|bounc\w*|spinner|loading|snappy|eas(e|ing)|delay\w*|motion|moves?|moving)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Eight frames from five seconds around `seconds` into the video, in a 4x2 grid labelled by time.
    // Each is cropped to the area around the pointer: a whole screen shrunk into a grid cell is too
    // small to see a modal slide in. The video and the stills share one scale, so `pointer` maps across.
    private nonisolated static func filmstrip(_ video: URL, around seconds: Double, pointer: CGPoint?,
                                              to file: URL) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let length = try? await asset.load(.duration).seconds else { return false }
        let lo = max(0, min(seconds, length) - 2.5), hi = min(length, lo + 5)
        guard hi > lo else { return false }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
        var images: [(CGImage, Double)] = []
        for i in 0..<8 {
            let t = lo + (hi - lo) * Double(i) / 7
            guard let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let w = min(frame.width, 720), h = min(frame.height, 450)
            // CGImage rows run top-down; the pointer is bottom-up.
            let center = pointer.map { CGPoint(x: $0.x, y: CGFloat(frame.height) - $0.y) }
                ?? CGPoint(x: frame.width / 2, y: frame.height / 2)
            let crop = CGRect(x: min(max(0, center.x - CGFloat(w) / 2), CGFloat(frame.width - w)),
                              y: min(max(0, center.y - CGFloat(h) / 2), CGFloat(frame.height - h)),
                              width: CGFloat(w), height: CGFloat(h))
            images.append((frame.cropping(to: crop) ?? frame, t - lo))
        }
        guard let first = images.first?.0,
              let ctx = CGContext(data: nil, width: first.width * 4, height: first.height * 2, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = nil }
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18),
                                                    .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]
        for (i, (image, t)) in images.enumerated() {
            let cell = CGRect(x: (i % 4) * first.width, y: (1 - i / 4) * first.height, width: first.width, height: first.height)
            ctx.draw(image, in: cell)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.stroke(cell, width: 2)
            NSString(string: String(format: " %.1fs ", t)).draw(at: CGPoint(x: cell.minX + 6, y: cell.maxY - 28), withAttributes: label)
        }
        guard let sheet = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: sheet).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return false }
        return (try? jpeg.write(to: file)) != nil
    }

    // Ten frames a second of the display under the pointer, straight to an mp4 by ScreenCaptureKit.
    private func startVideo() async {
        guard let (filter, screen) = await Self.target() else { return }
        let scale = min(1, 1440 / screen.frame.width)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * scale) & ~1
        cfg.height = Int(screen.frame.height * scale) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        let output = SCRecordingOutputConfiguration()
        output.outputURL = dir.appendingPathComponent("screen.mp4")
        output.outputFileType = .mp4
        let done = RecordingDone(url: output.outputURL)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        do {
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: done))
            try await stream.startCapture()
        } catch {
            logLine("annotate: no video, \(error.localizedDescription)")
            return
        }
        guard timer != nil else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        recording = done
        videoStart = Date()
    }

    private func stopVideo() async -> URL? {
        guard let stream, let recording else { return nil }
        self.stream = nil
        self.recording = nil
        try? await stream.stopCapture()
        // The file is only usable once the output says it is finished; never wait on it forever.
        Task { try? await Task.sleep(for: .seconds(4)); recording.resolve(false) }
        return await recording.finished() ? recording.url : nil
    }

    private func tick() async {
        guard !busy, timer != nil else { return }
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 30 {
            lastMouse = mouse
            lastMove = Date()
            hoverTaken = false
        }
        let still = Date().timeIntervalSince(lastMove)
        // A pointer left alone this long is no longer pointing at anything.
        if still > 10 { return }
        busy = true
        defer { busy = false }
        guard var f = await Self.grab() else { return }
        if still >= 1.5, !hoverTaken {
            hoverTaken = true
            f.kind = .hover
            keep(f)
        } else if frames.last.map({ Self.differs($0, f) }) ?? true {
            keep(f)
        }
    }

    private func keep(_ f: Frame) {
        frames.append(f)
        frames.sort { $0.t < $1.t }
        // ponytail: 10-minute ring, notes copy their frames out, so only a single longer dictation loses its start.
        frames.removeAll { $0.t < Date().addingTimeInterval(-600) }
    }

    // The display under the pointer, without BisprBlow's own windows.
    private static func target() async -> (SCContentFilter, NSScreen)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id })
        else { return nil }
        let me = content.applications.filter { $0.processID == getpid() }
        return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), screen)
    }

    // The 720x450 around the pointer of that display scaled to at most 1440pt wide, with a ring where
    // the pointer is: a quarter of a full screenshot's tokens, and the same answers in testing.
    // ponytail: the fingerprint is still taken from the whole screen, so `differs` sees changes off-crop.
    private static func grab() async -> Frame? {
        let mouse = NSEvent.mouseLocation
        guard let (filter, screen) = await target() else { return nil }
        let scale = min(1, 1440 / screen.frame.width)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * scale)
        cfg.height = Int(screen.frame.height * scale)
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
              let ctx = CGContext(data: nil, width: cfg.width, height: cfg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: cfg.width, height: cfg.height))
        // NSScreen and CGContext both put the origin bottom-left, so there is no y flip.
        let p = CGPoint(x: (mouse.x - screen.frame.minX) * scale, y: (mouse.y - screen.frame.minY) * scale)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
        let w = min(cfg.width, 720), h = min(cfg.height, 450)
        // CGImage crops run top-down; `p` is bottom-up.
        let crop = CGRect(x: min(max(0, p.x - CGFloat(w) / 2), CGFloat(cfg.width - w)).rounded(),
                          y: min(max(0, CGFloat(cfg.height) - p.y - CGFloat(h) / 2), CGFloat(cfg.height - h)).rounded(),
                          width: CGFloat(w), height: CGFloat(h))
        guard let marked = ctx.makeImage()?.cropping(to: crop),
              let jpeg = NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return nil }
        var print = [UInt8](repeating: 0, count: 32 * 32)
        CGContext(data: &print, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?
            .draw(img, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let at = ContextDetector.element(at: CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y))
        return Frame(t: Date(), jpeg: jpeg, mouse: p, print: print, element: at?.element ?? "", place: at?.place ?? "")
    }
}

// Tells `stopVideo` when the mp4 is finished, or that it never will be.
private final class RecordingDone: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    init(url: URL) { self.url = url }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { resolve(true) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { resolve(false) }

    func resolve(_ ok: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = ok
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: ok)
    }

    func finished() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
