import Testing
import Foundation
@testable import Lifehug

/// U2/U3 — ASR readiness state machine, gating, and final-transcription behavior.
/// The real WhisperKit model never loads on the simulator, so these tests drive the
/// state machine through the `loadOverrideForTesting` seam rather than a CoreML model.
@Suite("STTService")
@MainActor
struct STTServiceTests {

    private enum TestFailure: Error { case load }

    // MARK: - Readiness state machine (U2)

    @Test("Successful load walks idle -> loading -> ready")
    func loadReachesReady() async {
        let service = STTService()
        #expect(service.asrState == .idle)
        #expect(service.isASRReady == false)

        var stateSeenInsideLoad: ASRState?
        service.loadOverrideForTesting = { stateSeenInsideLoad = service.asrState }

        await service.loadASRModel()

        #expect(stateSeenInsideLoad == .loading)   // passed through .loading
        #expect(service.asrState == .ready)
        #expect(service.isASRReady == true)
    }

    @Test("A thrown load error lands in .failed with a user-facing message")
    func loadFailureSurfacesMessage() async {
        let service = STTService()
        service.loadOverrideForTesting = { throw TestFailure.load }

        await service.loadASRModel()

        guard case .failed(let message) = service.asrState else {
            Issue.record("expected .failed, got \(service.asrState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(service.isASRReady == false)
    }

    @Test("A failed load is retriable and can reach ready")
    func failedLoadRetries() async {
        let service = STTService()
        service.loadOverrideForTesting = { throw TestFailure.load }
        await service.loadASRModel()
        guard case .failed = service.asrState else {
            Issue.record("expected .failed after first attempt")
            return
        }

        // Retry with a succeeding loader.
        service.loadOverrideForTesting = { }
        await service.loadASRModel()
        #expect(service.asrState == .ready)
    }

    @Test("A load in flight / already ready is a no-op on re-entry")
    func loadIsIdempotentWhenReady() async {
        let service = STTService()
        service.loadOverrideForTesting = { }
        await service.loadASRModel()
        #expect(service.asrState == .ready)

        // Second call while ready must not throw the state back to loading.
        var overrideRan = false
        service.loadOverrideForTesting = { overrideRan = true }
        await service.loadASRModel()
        #expect(overrideRan == false)
        #expect(service.asrState == .ready)
    }

    // MARK: - Gating (U2)

    @Test("startListening while not ready returns an empty stream and a distinct error")
    func startListeningNotReadyIsSafe() async {
        let service = STTService()
        #expect(service.asrState != .ready)

        var yielded: [String] = []
        for await text in service.startListening() {
            yielded.append(text)
        }

        #expect(yielded.isEmpty)
        #expect(service.error != nil)
        // The message must be distinguishable from the empty-transcript failure.
        #expect(service.error != "I didn't catch that. Try again?")
    }

    @Test("startListening once ready produces the simulator mock transcript")
    func startListeningReadyYieldsMock() async {
        let service = STTService()
        service.loadOverrideForTesting = { }
        await service.loadASRModel()
        #expect(service.isASRReady)

        var yielded: [String] = []
        for await text in service.startListening() {
            yielded.append(text)
        }
        #expect(yielded.contains { !$0.isEmpty })
    }

    // MARK: - Final transcription + cap decision logic (U3)
    // The real full-buffer transcription is device-only (WhisperKit needs CoreML),
    // so the pure decision/formatting helpers are the unit-testable slice here; the
    // end-to-end recovery is verified on device in U14.

    @Test("final transcription runs only when partial is empty and buffer is large enough")
    func finalTranscriptionGate() {
        #expect(STTService.shouldRunFinalTranscription(partialIsEmpty: true, sampleCount: 8000))
        #expect(STTService.shouldRunFinalTranscription(partialIsEmpty: true, sampleCount: 16000))
        // Below the ~0.5s floor → skip.
        #expect(!STTService.shouldRunFinalTranscription(partialIsEmpty: true, sampleCount: 7999))
        // Streaming already produced text → skip (no redundant pass).
        #expect(!STTService.shouldRunFinalTranscription(partialIsEmpty: false, sampleCount: 100_000))
    }

    @Test("joinTranscriptionText joins segments and trims")
    func joinsSegments() {
        #expect(STTService.joinTranscriptionText(["Hello.", "How are you?"]) == "Hello. How are you?")
        #expect(STTService.joinTranscriptionText(["  spaced  "]) == "spaced")
        #expect(STTService.joinTranscriptionText([]) == "")
    }

    @Test("wall-clock cap trips past the limit, not before, and never when unset")
    func wallClockCap() {
        let now = Date()
        #expect(STTService.recordingExceededCap(start: now.addingTimeInterval(-200), now: now, cap: 180))
        #expect(!STTService.recordingExceededCap(start: now.addingTimeInterval(-10), now: now, cap: 180))
        #expect(!STTService.recordingExceededCap(start: nil, now: now, cap: 180))
    }
}
