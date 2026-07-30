import AVFoundation
import Speech

/// Streaming on-device transcription.
///
/// Primary path: the macOS 26 `SpeechAnalyzer` + `SpeechTranscriber` API (fast, fully
/// on-device, no quota). Fallback: `SFSpeechRecognizer` with on-device recognition.
final class Transcriber {
    enum TranscriberError: Error, LocalizedError {
        case localeUnsupported
        case noResult

        var errorDescription: String? {
            switch self {
            case .localeUnsupported: return "On-device transcription does not support this locale."
            case .noResult: return "No speech was recognized."
            }
        }
    }

    /// Volatile (in-progress) text, for live UI feedback.
    var onPartial: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var analyzerTranscriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""
    private var volatileText = ""

    // SFSpeechRecognizer fallback
    private var sfRecognizer: SFSpeechRecognizer?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?
    private var sfLatest = ""
    private var usingFallback = false

    /// Downloads the on-device model if needed. Call once at startup.
    static func prepareAssets() async {
        guard let locale = await bestLocale() else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            NSLog("BluejayWispr: speech asset install failed: \(error)")
        }
    }

    private static func bestLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let match = supported.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return match
        }
        if let lang = current.language.languageCode?.identifier,
           let match = supported.first(where: { $0.language.languageCode?.identifier == lang }) {
            return match
        }
        return supported.first(where: { $0.language.languageCode?.identifier == "en" })
    }

    // MARK: - Session

    func startSession(inputFormat: AVAudioFormat) async {
        finalizedText = ""
        volatileText = ""
        sfLatest = ""
        usingFallback = false
        do {
            try await startAnalyzerSession(inputFormat: inputFormat)
        } catch {
            NSLog("BluejayWispr: SpeechAnalyzer unavailable (\(error)); falling back to SFSpeechRecognizer")
            usingFallback = true
            startSFSession(inputFormat: inputFormat)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        if usingFallback {
            sfRequest?.append(buffer)
            return
        }
        guard let analyzerFormat, let inputBuilder else { return }
        if buffer.format == analyzerFormat {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let converter,
              let out = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * analyzerFormat.sampleRate / buffer.format.sampleRate) + 16)
        else { return }
        var fed = false
        var convertError: NSError?
        converter.convert(to: out, error: &convertError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if convertError == nil, out.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Stops the session and returns the full transcript.
    func finishSession() async -> String {
        if usingFallback { return await finishSFSession() }

        inputBuilder?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("BluejayWispr: analyzer finalize error: \(error)")
        }
        await resultsTask?.value
        cleanupAnalyzer()
        let text = (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    func cancelSession() async {
        if usingFallback {
            sfTask?.cancel()
            sfRequest?.endAudio()
            sfTask = nil
            sfRequest = nil
            return
        }
        inputBuilder?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        cleanupAnalyzer()
    }

    // MARK: - SpeechAnalyzer path

    private func startAnalyzerSession(inputFormat: AVAudioFormat) async throws {
        guard let locale = await Self.bestLocale() else { throw TranscriberError.localeUnsupported }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        // Bias the recognizer toward the user's vocabulary. Fixing "proud" back to "prod" in
        // cleanup can't work: by then the word "prod" was never in the transcript at all.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let vocabulary = await MainActor.run { AppSettings.shared.vocabulary }
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try? await analyzer.setContext(context)
        }
        self.analyzerTranscriber = transcriber
        self.analyzer = analyzer

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = format
        if let format, format != inputFormat {
            self.converter = AVAudioConverter(from: inputFormat, to: format)
        } else {
            self.converter = nil
        }

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = builder

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    let snapshot = self.finalizedText + self.volatileText
                    DispatchQueue.main.async { self.onPartial?(snapshot) }
                }
            } catch {
                NSLog("BluejayWispr: transcriber results error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: sequence)
    }

    private func cleanupAnalyzer() {
        analyzer = nil
        analyzerTranscriber = nil
        inputBuilder = nil
        analyzerFormat = nil
        converter = nil
        resultsTask = nil
    }

    // MARK: - SFSpeechRecognizer fallback

    private func startSFSession(inputFormat: AVAudioFormat) {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = AppSettings.shared.vocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        sfRecognizer = recognizer
        sfRequest = request
        sfTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.sfLatest = result.bestTranscription.formattedString
            let snapshot = self.sfLatest
            DispatchQueue.main.async { self.onPartial?(snapshot) }
        }
    }

    private func finishSFSession() async -> String {
        sfRequest?.endAudio()
        // Give the recognizer a moment to emit its final result.
        for _ in 0..<30 {
            if sfTask?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        sfTask?.cancel()
        sfTask = nil
        sfRequest = nil
        return sfLatest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
