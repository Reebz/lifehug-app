import Testing
import Foundation
@testable import Lifehug

/// U4 (Kokoro failure → system fallback) and U5 (system-TTS didCancel + generation
/// gated timeout). The actual synthesis/playback fallback is device/integration
/// behavior; the unit-testable slices are the error surface, the useKokoro gate,
/// and the timeout generation predicate.
@Suite("TTSService")
@MainActor
struct TTSServiceTests {

    // MARK: - U4: Kokoro error surface + degradation gate

    @Test("Kokoro playback/empty errors carry user-facing descriptions")
    func kokoroErrorsHaveDescriptions() {
        #expect(KokoroManager.KokoroError.playbackFailed.errorDescription?.isEmpty == false)
        #expect(KokoroManager.KokoroError.emptyAudio.errorDescription?.isEmpty == false)
        #expect(KokoroManager.KokoroError.engineNotLoaded.errorDescription?.isEmpty == false)
    }

    @Test("useKokoro is false with no engine and when force-degraded")
    func useKokoroGate() {
        let tts = TTSService()
        // No KokoroManager attached and Kokoro disabled by default → system voice.
        #expect(tts.useKokoro == false)

        tts.forceDegradedToSystem = true
        #expect(tts.useKokoro == false)
    }

    // MARK: - U5: timeout generation gate

    @Test("A fired timeout stops only its own generation")
    func timeoutGeneration() {
        #expect(TTSService.timeoutShouldStop(timeoutGeneration: 3, currentGeneration: 3))
        #expect(!TTSService.timeoutShouldStop(timeoutGeneration: 3, currentGeneration: 4))
        #expect(!TTSService.timeoutShouldStop(timeoutGeneration: 0, currentGeneration: 1))
    }
}
