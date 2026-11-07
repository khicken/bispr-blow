// Apple SpeechAnalyzer + SpeechTranscriber baseline for the ASR bench, configured exactly like
// Sources/BisprBlow/Transcriber.swift (startAnalyzerSession, bestLocale, withoutPauseMarks).
//
//   swift bench/asr/apple_transcribe.swift --vocab bench/asr/vocab.txt a.wav b.wav
//
// Prints one JSON line per file: {"file", "text", "ms"}; ms is analysis wall time, asset install
// excluded. Top-level await, never a semaphore: a Task blocked on the main thread deadlocks.

import AVFoundation
import Foundation
import Speech

func withoutPauseMarks(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s*(\\.{3,}|…)\\s*", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func bestLocale() async -> Locale? {
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

func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .alternativeTranscriptions],
        attributeOptions: [.transcriptionConfidence]
    )
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("apple_transcribe: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var vocabulary: [String] = []
if let i = args.firstIndex(of: "--vocab") {
    guard i + 1 < args.count else { fail("--vocab needs a path") }
    let contents = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    vocabulary = contents.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    args.removeSubrange(i...(i + 1))
}
guard !args.isEmpty else { fail("usage: apple_transcribe.swift [--vocab vocab.txt] file.wav ...") }

guard let locale = await bestLocale() else { fail("no supported locale") }
do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale)]) {
        try await request.downloadAndInstall()
    }
} catch {
    fail("asset install failed: \(error)")
}

for path in args {
    let url = URL(fileURLWithPath: path)
    let start = Date()
    let transcriber = makeTranscriber(locale)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if !vocabulary.isEmpty {
        let context = AnalysisContext()
        context.contextualStrings = [.general: vocabulary]
        try? await analyzer.setContext(context)
    }
    let collector = Task {
        var finalized = ""
        for try await result in transcriber.results where result.isFinal {
            finalized += String(result.text.characters)
        }
        return finalized
    }
    let text: String
    do {
        let file = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        text = withoutPauseMarks(try await collector.value)
    } catch {
        collector.cancel()
        fail("\(url.lastPathComponent): \(error)")
    }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let line: [String: Any] = ["file": url.lastPathComponent, "text": text, "ms": ms]
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}
