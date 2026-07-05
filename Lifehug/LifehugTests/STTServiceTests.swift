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
}
