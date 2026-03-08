import Foundation
import AVFoundation
import os

@Observable
@MainActor
final class TTSService {
    var isSpeaking: Bool = false
    var useSystemTTS: Bool = true
    var forceDegradedToSystem: Bool = false

    /// Called when all queued sentences have finished speaking.
    /// VoicePipeline uses this to auto-resume listening.
    var onAllSpeechFinished: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "com.lifehug.app", category: "TTS")
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: TTSDelegate?
    private var sentenceQueue: [String] = []
    private var speakingTask: Task<Void, Never>?
    private(set) var kokoroManager: KokoroManager?

    /// Whether Kokoro neural TTS should be used for speech.
    var useKokoro: Bool {
        KokoroManager.isEnabled
        && kokoroManager?.isReady == true
        && !forceDegradedToSystem
    }

    func setKokoroManager(_ manager: KokoroManager) {
        kokoroManager = manager
    }

    init() {
        delegate = TTSDelegate { @Sendable [weak self] in
            Task { @MainActor in
                self?.onUtteranceFinished()
            }
        }
        synthesizer.delegate = delegate
    }

    func speak(_ sentence: String) async {
        if useKokoro {
            isSpeaking = true
            await kokoroManager?.speak(sentence)
            isSpeaking = false
            onAllSpeechFinished?()
            return
        }
        sentenceQueue.append(sentence)
        if !isSpeaking {
            await processSentenceQueue()
        }
    }

    func stop() {
        sentenceQueue.removeAll()
        kokoroManager?.stopPlayback()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingTask?.cancel()
        speakingTask = nil
    }

    func degradeToSystemTTS() {
        useSystemTTS = true
        forceDegradedToSystem = true
        logger.warning("Degraded to system TTS (memory pressure)")
    }

    private func processSentenceQueue() async {
        guard !sentenceQueue.isEmpty else {
            isSpeaking = false
            onAllSpeechFinished?()
            return
        }

        isSpeaking = true
        let sentence = sentenceQueue.removeFirst()

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestAvailableVoice()
        utterance.rate = 0.48 // Slightly unhurried for warm interviewer tone
        utterance.pitchMultiplier = 1.0 // Natural pitch
        utterance.postUtteranceDelay = 0.15 // Brief pause between sentences

        synthesizer.speak(utterance)
    }

    private func onUtteranceFinished() {
        if !sentenceQueue.isEmpty {
            Task {
                await processSentenceQueue()
            }
        } else {
            isSpeaking = false
            onAllSpeechFinished?()
        }
    }

    /// Select the best available on-device voice for the given language.
    /// Prefers named voices (Zoe, Ava, Joelle, Noelle), then premium > enhanced > default quality.
    private static func bestAvailableVoice(for language: String = "en-US") -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }

        let preferredNames = ["Zoe", "Ava", "Joelle", "Noelle"]
        for name in preferredNames {
            if let match = voices.first(where: { $0.name.contains(name) && $0.quality == .premium }) {
                return match
            }
        }
        for name in preferredNames {
            if let match = voices.first(where: { $0.name.contains(name) && $0.quality == .enhanced }) {
                return match
            }
        }
        for name in preferredNames {
            if let match = voices.first(where: { $0.name.contains(name) }) {
                return match
            }
        }

        if let premium = voices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}

private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let onFinished: @Sendable () -> Void

    init(onFinished: @escaping @Sendable () -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinished()
    }
}
