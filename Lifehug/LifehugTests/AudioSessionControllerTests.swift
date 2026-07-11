import Testing
import Foundation
@testable import Lifehug

/// U9 — single app-side audio-session owner: teardown ordering, the idempotence latch,
/// and the record-epoch stale-deactivation guard. AVAudioSession calls run against the
/// simulator's session and any failure lands in the controller's own do/catch, so these
/// tests exercise sequencing and state, not audio hardware.
@Suite("AudioSessionController")
@MainActor
struct AudioSessionControllerTests {

    @Test("end() runs the teardown closure and clears the latch")
    func endRunsTeardownThenDeactivates() async {
        let controller = AudioSessionController()
        var teardownRan = false
        await controller.end { teardownRan = true }
        #expect(teardownRan)
        #expect(controller.isConfigured == false)
    }

    @Test("beginRecordPhase bumps the epoch on every call, latched or not")
    func recordPhaseAlwaysBumpsEpoch() {
        let controller = AudioSessionController()
        let start = controller.recordEpoch
        controller.beginRecordPhase()
        controller.beginRecordPhase()  // latched second call still counts as a claim
        #expect(controller.recordEpoch == start + 2)
    }

    @Test("a record phase during teardown makes end() skip the stale deactivation")
    func staleEndSkipsDeactivation() async {
        let controller = AudioSessionController()
        controller.beginRecordPhase()
        var configuredAfterSuccessorClaim = false
        await controller.end {
            // A successor session claims the audio session mid-teardown.
            controller.beginRecordPhase()
            configuredAfterSuccessorClaim = controller.isConfigured
        }
        // The stale end() must leave the successor's configuration untouched.
        #expect(controller.isConfigured == configuredAfterSuccessorClaim)
    }

    @Test("invalidate drops the latch so the next record phase re-asserts")
    func invalidateDropsLatch() {
        let controller = AudioSessionController()
        controller.beginRecordPhase()
        controller.invalidate()
        #expect(controller.isConfigured == false)
    }
}
