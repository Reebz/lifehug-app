import AVFoundation
import os

/// The single app-side owner of the shared `AVAudioSession` (U9 / KTD4).
///
/// WhisperKit's `AudioProcessor` still reconfigures the session internally on every
/// recording (that code lives inside the pinned dependency), so this controller does
/// not try to own everything — it sequences *around* WhisperKit and aligns the app's
/// category options with WhisperKit's superset (adding `.allowBluetoothA2DP`) so any
/// residual app-side `setCategory` is not a meaningfully different config. It is the
/// only app-side caller of `setCategory`/`setActive`.
///
/// It is app-scoped (`shared`) so it survives the fresh `VoicePipeline` built on every
/// voice-mode entry — the durable owner is the controller, not a per-instance flag (P2-10).
@MainActor
final class AudioSessionController {
    /// App-scoped instance. A voice session's `VoicePipeline` borrows this by default so
    /// the audio-session owner outlives any single pipeline.
    static let shared = AudioSessionController()

    private let logger = Logger(subsystem: "com.lifehug.app", category: "AudioSession")

    /// App-side category options — the superset of WhisperKit's internal options (adds
    /// `.allowBluetoothA2DP`) so the app never asserts a *meaningfully* different category.
    private static let recordOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP
    ]

    /// Whether the category+activation is currently asserted. Reset by `invalidate()`
    /// so the next record phase re-asserts unconditionally (e.g. after an interruption).
    /// `private(set)` so tests can observe the latch.
    private(set) var isConfigured = false

    /// Monotonic record-phase epoch, bumped on EVERY beginRecordPhase() call (latched
    /// or not). `end()` captures it before its teardown await and skips deactivation if
    /// a newer record phase claimed the session meanwhile — an exited pipeline's slow
    /// teardown must never setActive(false) under a successor's live recording.
    private(set) var recordEpoch = 0

    /// Ensure the session is `.playAndRecord` and active for recording. Idempotent —
    /// never re-sets the category while already configured (avoids thrashing WhisperKit).
    func beginRecordPhase() {
        recordEpoch += 1
        guard !isConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.recordOptions)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isConfigured = true
            logger.info("Audio session configured for record phase")
        } catch {
            logger.error("beginRecordPhase failed: \(error)")
        }
    }

    /// Assert the session is active for playback. Never changes the category — the
    /// record-phase `.playAndRecord` category already covers playback.
    func beginPlaybackPhase() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("beginPlaybackPhase failed: \(error)")
        }
    }

    /// Deactivate the session so other apps (music, podcasts) resume — but only after
    /// the STT engine has fully torn down, so deactivation never races a live recording
    /// engine (fixes the `IsBusy` throw, P2-3). `teardown` is the awaitable STT stop.
    func end(afterTeardown teardown: () async -> Void) async {
        let epoch = recordEpoch
        await teardown()
        // A newer record phase started while we awaited the teardown — the session now
        // belongs to that successor; deactivating would kill its live recording.
        guard epoch == recordEpoch else {
            logger.info("Audio session deactivation skipped — newer record phase active")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("Audio session deactivated")
        } catch {
            logger.error("end/deactivate failed: \(error)")
        }
        isConfigured = false
    }

    /// Drop the idempotence latch so the next `beginRecordPhase()` re-asserts the
    /// category unconditionally (used when an interruption begins, P2-4).
    func invalidate() {
        isConfigured = false
    }

    /// Re-activate and re-assert the category after an interruption ends.
    func reactivateAfterInterruption() {
        isConfigured = false
        beginRecordPhase()
    }
}
