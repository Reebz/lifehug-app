import Foundation
import AVFoundation
import os

@Observable
@MainActor
final class TTSService {
    var isSpeaking: Bool = false
    var forceDegradedToSystem: Bool = false

    private let logger = Logger(subsystem: "com.lifehug.app", category: "TTS")
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: TTSDelegate?
    private var speakGeneration: Int = 0
    private(set) var kokoroManager: KokoroManager?
    private static var cachedVoice: AVSpeechSynthesisVoice?

    /// Whether Kokoro neural TTS should be used for speech.
    var useKokoro: Bool {
        KokoroManager.isEnabled
        && kokoroManager?.isReady == true
        && !forceDegradedToSystem
    }

    func setKokoroManager(_ manager: KokoroManager) {
        kokoroManager = manager
    }

    init() {}

    func speak(_ sentence: String) async {
        if useKokoro {
            isSpeaking = true
            do {
                try await kokoroManager?.speak(sentence)
            } catch {
                logger.warning("Kokoro synthesis failed, degrading to system TTS: \(error)")
                forceDegradedToSystem = true
                // Fall through to system TTS for this sentence
                isSpeaking = false
                await speakViaSystem(sentence)
                return
            }
            isSpeaking = false
            return
        }
        await speakViaSystem(sentence)
    }

    private func speakViaSystem(_ sentence: String) async {
        isSpeaking = true
        speakGeneration += 1
        let generation = speakGeneration

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestAvailableVoice()
        utterance.rate = 0.53
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.15

        do {
            try await withTimeout(seconds: 15) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // Double-resume guard: timeout and delegate can both fire
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    self.delegate = TTSDelegate { @Sendable in
                        resumed.withLock { alreadyResumed in
                            guard !alreadyResumed else { return }
                            alreadyResumed = true
                            Task { @MainActor in continuation.resume() }
                        }
                    }
                    self.synthesizer.delegate = self.delegate
                    self.synthesizer.speak(utterance)
                }
            }
        } catch is TimeoutError {
            logger.warning("System TTS timed out after 15s — stopping synthesizer")
            synthesizer.stopSpeaking(at: .immediate)
        }
        if generation == speakGeneration {
            isSpeaking = false
        }
    }

    func stop() {
        speakGeneration += 1
        kokoroManager?.stopPlayback()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        // The delegate's double-resume guard handles any pending continuation safely.
    }

    func degradeToSystemTTS() {
        forceDegradedToSystem = true
        logger.warning("Degraded to system TTS (memory pressure)")
    }

    /// Unload the Kokoro model weights (~80MB) to reclaim memory.
    func unloadKokoroModel() {
        kokoroManager?.unloadEngine()
        logger.info("Kokoro model unloaded via TTSService (memory pressure)")
    }

    /// Select the best available on-device voice for the given language.
    /// Prefers named voices (Zoe, Ava, Joelle, Noelle), then premium > enhanced > default quality.
    private static func bestAvailableVoice(for language: String = "en-US") -> AVSpeechSynthesisVoice? {
        if let cached = cachedVoice {
            return cached
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }

        let preferredNames = ["Zoe", "Ava", "Joelle", "Noelle"]
        let preferredQualities: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]

        // Search preferred names at each quality tier
        for quality in preferredQualities {
            for name in preferredNames {
                if let match = voices.first(where: { $0.name.contains(name) && $0.quality == quality }) {
                    cachedVoice = match
                    return match
                }
            }
        }

        // Fall back to any voice by quality
        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced] {
            if let match = voices.first(where: { $0.quality == quality }) {
                cachedVoice = match
                return match
            }
        }

        let fallback = AVSpeechSynthesisVoice(language: language)
        cachedVoice = fallback
        return fallback
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
