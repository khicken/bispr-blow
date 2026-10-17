import AVFoundation

// Jay's short spoken replies. The duration estimate is what the listener ignores afterwards, since the
// mic hears the speakers.
@MainActor enum JayVoice {
    private static let wordsPerSecond = 2.8
    private static let startDelay: TimeInterval = 0.2
    // A static is created on first use, so the synthesizer costs nothing until Jay first speaks.
    private static let synthesizer = AVSpeechSynthesizer()

    static var isSpeaking: Bool { synthesizer.isSpeaking }

    @discardableResult
    static func say(_ phrase: String) -> TimeInterval {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: phrase))
        return startDelay + Double(phrase.split(separator: " ").count) / wordsPerSecond
    }
}
