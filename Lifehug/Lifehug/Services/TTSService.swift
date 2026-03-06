import Foundation
import AVFoundation
import os

@Observable
@MainActor
final class TTSService {
    var isSpeaking: Bool = false
    var useSystemTTS: Bool = true // Start with system TTS; Kokoro added in Phase 3+

    private let logger = Logger(subsystem: "com.lifehug.app", category: "TTS")
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: TTSDelegate?
    private var sentenceQueue: [String] = []
    private var speakingTask: Task<Void, Never>?

    init() {
        delegate = TTSDelegate { [weak self] in
            Task { @MainActor in
                self?.onUtteranceFinished()
            }
        }
        synthesizer.delegate = delegate
    }

    func speak(_ sentence: String) async {
        sentenceQueue.append(sentence)
        if !isSpeaking {
            await processSentenceQueue()
        }
    }

    func stop() {
        sentenceQueue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingTask?.cancel()
        speakingTask = nil
    }

    func degradeToSystemTTS() {
        useSystemTTS = true
        logger.warning("Degraded to system TTS (memory pressure)")
    }

    private func processSentenceQueue() async {
        guard !sentenceQueue.isEmpty else {
            isSpeaking = false
            return
        }

        isSpeaking = true
        let sentence = sentenceQueue.removeFirst()

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    private func onUtteranceFinished() {
        if !sentenceQueue.isEmpty {
            Task {
                await processSentenceQueue()
            }
        } else {
            isSpeaking = false
        }
    }
}

private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinished()
    }
}
