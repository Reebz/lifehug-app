import Foundation
import AVFoundation
import os

@Observable
@MainActor
final class TTSService {
    var forceDegradedToSystem: Bool = false

    private let logger = Logger(subsystem: "com.lifehug.app", category: "TTS")

    /// System speech synthesizer, created lazily on first system-TTS use. Building it
    /// eagerly spins up Apple's TextToSpeech/AXSpeech subsystem, which over-releases a
    /// Swift object on teardown on the iOS 26 simulator (SIGABRT: "pointer being freed
    /// was not allocated"). Deferring construction means Kokoro-only sessions — and unit
    /// tests that construct TTSService without ever speaking — never touch it.
    private var _synthesizer: AVSpeechSynthesizer?
    private var synthesizer: AVSpeechSynthesizer {
        if let existing = _synthesizer { return existing }
        let created = AVSpeechSynthesizer()
        _synthesizer = created
        return created
    }
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
            do {
                try await kokoroManager?.speak(sentence)
            } catch {
                logger.warning("Kokoro synthesis/playback failed, using system voice for this utterance: \(error)")
                kokoroManager?.stopPlayback()
                // Degrade for THIS utterance only — do NOT latch forceDegradedToSystem
                // for a transient playback/synthesis failure. The permanent-latch and
                // its recovery are handled by memory-pressure logic (U10).
                await speakViaSystem(sentence)
                return
            }
            return
        }
        await speakViaSystem(sentence)
    }

    private func speakViaSystem(_ sentence: String) async {
        speakGeneration += 1

        #if targetEnvironment(simulator)
        // Apple's AVSpeechSynthesizer over-releases a Swift object on teardown on the
        // iOS 26 simulator (SIGABRT: "pointer being freed was not allocated", zero app
        // frames — not an app-code bug). STT and LLM already run mocked on the sim; mock
        // system TTS the same way rather than ever driving the real synthesizer. Simulate
        // speech duration so the pipeline's .speaking timing (and auto-reopen) stays
        // realistic; the sleep is cancelled when the enclosing task is (stop/interrupt).
        let wordCount = max(1, sentence.split(whereSeparator: { $0.isWhitespace }).count)
        // ~0.33s/word approximates the 0.53 utterance rate; clamp so it never stalls.
        let seconds = min(Double(wordCount) * 0.33, 6.0)
        try? await Task.sleep(for: .seconds(seconds))
        return
        #else
        let generation = speakGeneration

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.bestAvailableVoice()
        utterance.rate = 0.53
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.15

        // Timeout via cancellable sleep task — avoids task group `sending` issues
        // with non-Sendable AVSpeechUtterance and MainActor-isolated self.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(15))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            self.delegate = TTSDelegate { @Sendable in
                resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return }
                    alreadyResumed = true
                    timeoutTask.cancel()
                    Task { @MainActor in continuation.resume() }
                }
            }
            self.synthesizer.delegate = self.delegate
            self.synthesizer.speak(utterance)

            // Fire timeout: if sleep completes (not cancelled), force-resume
            Task { [weak self] in
                do {
                    try await timeoutTask.value
                    // Timeout expired — force resume
                    resumed.withLock { alreadyResumed in
                        guard !alreadyResumed else { return }
                        alreadyResumed = true
                        Task { @MainActor in
                            guard let self else { continuation.resume(); return }
                            // Only stop the synthesizer if this timeout still belongs to
                            // the current utterance — a stale timeout must not cut off a
                            // newer one (generation gate).
                            if Self.timeoutShouldStop(timeoutGeneration: generation, currentGeneration: self.speakGeneration) {
                                self.logger.warning("System TTS timed out after 15s — stopping synthesizer")
                                self.synthesizer.stopSpeaking(at: .immediate)
                            }
                            continuation.resume()
                        }
                    }
                } catch {
                    // Cancelled — speech completed normally, nothing to do
                }
            }
        }
        #endif
    }

    func stop() {
        speakGeneration += 1
        kokoroManager?.stopPlayback()
        // Only touch the synthesizer if one was ever created — stopping never needs to
        // spin up the system speech subsystem (see `synthesizer` lazy note).
        _synthesizer?.stopSpeaking(at: .immediate)
        // The delegate's double-resume guard handles any pending continuation safely.
    }

    /// Whether a fired system-TTS timeout should still stop the synthesizer: only
    /// when its generation matches the current one (else a newer utterance is live).
    nonisolated static func timeoutShouldStop(timeoutGeneration: Int, currentGeneration: Int) -> Bool {
        timeoutGeneration == currentGeneration
    }

    /// Clear the cached system voice so a newly-installed or higher-quality voice is
    /// picked up on the next utterance (system-voice quality only).
    func invalidateVoiceCache() {
        Self.cachedVoice = nil
    }

    func degradeToSystemTTS() {
        forceDegradedToSystem = true
        logger.warning("Degraded to system TTS (memory pressure)")
    }

    /// Recover from a prior degradation once memory is healthy again (P2-2). Clears the
    /// force-degrade latch and reloads Kokoro if pressure had unloaded or failed it, so
    /// degradation is recoverable within a session rather than a one-way latch.
    func recoverFromDegradationIfNeeded() {
        if forceDegradedToSystem {
            forceDegradedToSystem = false
            logger.info("Memory normalized — cleared system-TTS degradation latch")
        }
        if KokoroManager.isEnabled, kokoroManager?.isReady == false {
            // Cooldown: this runs at the start of every conversation turn, and each
            // loadEngine() attempt on a persistent non-memory failure is a fresh
            // (180s-bounded) download/init. Throttle so a broken Kokoro doesn't cost
            // every turn; the latch-clear above stays unthrottled.
            let now = Date()
            if let last = lastKokoroRecoveryAttempt,
               now.timeIntervalSince(last) < Self.kokoroRecoveryCooldown {
                return
            }
            lastKokoroRecoveryAttempt = now
            Task { [kokoroManager] in await kokoroManager?.loadEngine() }
        }
    }

    /// Last recovery-driven loadEngine trigger; see cooldown note above.
    private var lastKokoroRecoveryAttempt: Date?
    private static let kokoroRecoveryCooldown: TimeInterval = 60

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

    /// `stopSpeaking(at:)` fires didCancel, not didFinish. Without this, a stopped
    /// utterance never resumes its continuation and never cancels its timeout task,
    /// leaking a timer that later stops a subsequent utterance (U5).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinished()
    }
}
