import AVFoundation
import Speech

// Streaming on-device transcription. Primary path: the macOS 26 `SpeechAnalyzer` +
// `SpeechTranscriber` API. Fallback: `SFSpeechRecognizer` with on-device recognition.
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

    // Volatile (in-progress) text, for live UI feedback.
    var onPartial: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var analyzerTranscriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    // The format `converter` was built from, so a buffer arriving in some other format rebuilds it
    // rather than being fed to a converter that cannot read it. See `feed`.
    private var converterInputFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""
    private var volatileText = ""

    // SFSpeechRecognizer fallback
    private var sfRecognizer: SFSpeechRecognizer?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?
    private var sfLatest = ""
    private var usingFallback = false

    // Drops the ellipsis the recognizer writes where the speaker paused: punctuation it invented,
    // not a word anybody said, and it does two kinds of damage. It reaches the cursor ("again to
    // see... If we already offloaded this work" is verbatim from history), because cleanup is told
    // never to WRITE an ellipsis and so copies this one through. Worse, it disarms a guard:
    // `looksTruncated` reads an ellipsis in the transcript as proof the speaker dictated one, so on
    // any dictation containing a pause a model that trailed off sailed through. Fixing it at the
    // source is what keeps that check armed.
    //
    // Three dots minimum, so a spoken relative path ("dot dot slash src") is not eaten. The
    // following word keeps its case — lowercasing blindly here would ruin "see... Kubernetes".
    static func withoutPauseMarks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*(\\.{3,}|…)\\s*", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Downloads the on-device model if needed. Call once at startup.
    static func prepareAssets() async {
        guard let locale = await bestLocale() else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            logLine("speech asset install failed: \(error)")
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

    // No `inputFormat` parameter: the converter is built from the first buffer that actually arrives
    // (see `feed`), which is the only format guaranteed to be the real one.
    func startSession(contextTerms: [String] = []) async {
        finalizedText = ""
        volatileText = ""
        sfLatest = ""
        usingFallback = false
        do {
            try await startAnalyzerSession(contextTerms: contextTerms)
        } catch {
            logLine("SpeechAnalyzer unavailable (\(error)); falling back to SFSpeechRecognizer")
            usingFallback = true
            startSFSession(contextTerms: contextTerms)
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
        // Built from the buffer in hand, never from a format read earlier. `beginRecording` read
        // `recorder.inputFormat` BEFORE `AudioRecorder.start` applied the selected device, so on any
        // mic at a different sample rate the converter was built for a format the buffers never had
        // — and AVAudioConverter does not recover, it silently yields nothing for the whole
        // dictation. Keying on the format also survives a device change mid-session.
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converterInputFormat = buffer.format
            logLine("audio converting \(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch → \(Int(analyzerFormat.sampleRate))Hz/\(analyzerFormat.channelCount)ch")
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

    // Stops the session and returns the full transcript.
    func finishSession() async -> String {
        if usingFallback { return await finishSFSession() }

        inputBuilder?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logLine("analyzer finalize error: \(error)")
        }
        await resultsTask?.value
        cleanupAnalyzer()
        return Self.withoutPauseMarks(finalizedText + volatileText)
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

    private func startAnalyzerSession(contextTerms: [String]) async throws {
        guard let locale = await Self.bestLocale() else { throw TranscriberError.localeUnsupported }
        // Alternatives and confidence cost nothing to ask for and are the raw material every
        // recognition fix needs: if a term is anywhere in the n-best, choosing it is free accuracy.
        // Published ablations put 1-best-only rewriting at roughly break-even, and negative
        // zero-shot, while n-best is where the gains are.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.transcriptionConfidence]
        )
        // NOTE: contextualStrings below is very likely a NO-OP on this module. Apple DTS, twice:
        // contextual strings only help the DictationTranscriber module, and SpeechTranscriber does
        // not take them into account (developer.apple.com/forums/thread/811083, /801877). It fails
        // silently, so it cannot be smoke-tested by "looks fine". Confirmed structurally on this
        // SDK: `SpeechTranscriber` has no `contentHints:` parameter while `DictationTranscriber`
        // does, so the real biasing door — SFCustomLanguageModelData — opens only onto the older,
        // weaker acoustic model. Left in place because it is harmless and load-bearing on the
        // SFSpeechRecognizer fallback (capped at 100 phrases). Do not tune it until the no-op is
        // confirmed at runtime.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let vocabulary = await MainActor.run { AppSettings.shared.vocabulary } + contextTerms
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try? await analyzer.setContext(context)
        }
        self.analyzerTranscriber = transcriber
        self.analyzer = analyzer

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = format
        self.converter = nil
        self.converterInputFormat = nil

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = builder

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        // Whether `alternatives` is populated, and how deep, is undocumented, and it
                        // decides whether n-best rescoring is worth building. A CLI probe cannot ask
                        // (no Speech authorization). Counts only, never the text: the unified log is
                        // readable by anything on the machine.
                        logLine("alternatives=\(result.alternatives.count) for \(text.split(whereSeparator: \.isWhitespace).count)w span")
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    let snapshot = Self.withoutPauseMarks(self.finalizedText + self.volatileText)
                    DispatchQueue.main.async { self.onPartial?(snapshot) }
                }
            } catch {
                logLine("transcriber results error: \(error)")
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
        converterInputFormat = nil
        resultsTask = nil
    }

    // MARK: - SFSpeechRecognizer fallback

    private func startSFSession(contextTerms: [String]) {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = AppSettings.shared.vocabulary + contextTerms
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        sfRecognizer = recognizer
        sfRequest = request
        sfTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.sfLatest = result.bestTranscription.formattedString
            let snapshot = Self.withoutPauseMarks(self.sfLatest)
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
        return Self.withoutPauseMarks(sfLatest)
    }
}
