import AVFoundation
import Foundation
import os

/// Plays an answer's clips in order from the answer browser, routed through the app's single
/// audio-session owner (KTD11). Standalone `AVQueuePlayer` — deliberately not reusing
/// `KokoroManager`'s private, TTS-entangled player; it mirrors the same double-resume-guard
/// shape instead. The browser runs outside any pipeline, so it activates the session itself
/// and refuses to start while a recording session is live.
@Observable
@MainActor
final class AudioClipPlayer {
    enum PlaybackState: Equatable { case idle, playing, paused, finished }

    private(set) var state: PlaybackState = .idle
    /// Filename of the clip currently playing, for row highlighting; nil when idle/finished.
    private(set) var currentClipName: String?
    /// Set briefly when a play attempt is refused because a recording session is live (KTD11).
    private(set) var refusedWhileRecording = false

    private let audioSession: AudioSessionController
    /// Reports whether a recording session is live so playback can refuse to fight the
    /// recording stack. Settable so a view can wire it to `STTService.isRecording` after the
    /// player is constructed (the check isn't available at `@State` init time).
    var recordingActive: @MainActor () -> Bool
    private static let logger = Logger(subsystem: "com.lifehug.app", category: "ClipPlayer")

    private var player: AVQueuePlayer?
    private var queuedNames: [String] = []
    private var finishedIndex = 0
    private var endObservers: [any NSObjectProtocol] = []
    private var interruptionObserver: (any NSObjectProtocol)?

    /// `recordingActive` reports whether a recording session is live, so playback can refuse
    /// to fight the recording stack. Defaults to always-false for previews/tests.
    init(
        audioSession: AudioSessionController = .shared,
        recordingActive: @escaping @MainActor () -> Bool = { false }
    ) {
        self.audioSession = audioSession
        self.recordingActive = recordingActive
    }

    /// Ordered (name, url) pairs for the playable segments — clip-less segments are skipped,
    /// order preserved. Pure so queue construction is unit-testable.
    static func playableClips(
        from segments: [Answer.Segment],
        clipURL: (String) -> URL?
    ) -> [(name: String, url: URL)] {
        segments.compactMap { seg in
            guard let name = seg.clipFilename, let url = clipURL(name) else { return nil }
            return (name, url)
        }
    }

    /// Start playing `clips` in order. Refused (no-op + notice) while a recording session is
    /// live. Missing files are skipped; an all-missing/empty queue lands in `.finished`.
    func play(_ clips: [(name: String, url: URL)]) {
        guard !recordingActive() else {
            refusedWhileRecording = true
            state = .idle
            return
        }
        refusedWhileRecording = false
        teardownPlayer()

        let existing = clips.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existing.isEmpty else {
            state = .finished
            currentClipName = nil
            return
        }

        // Activate the session for playback via the single owner, honoring the record-epoch
        // stale-deactivation guard (KTD11).
        audioSession.beginPlaybackPhase()

        let items = existing.map { AVPlayerItem(url: $0.url) }
        queuedNames = existing.map(\.name)
        finishedIndex = 0
        let queue = AVQueuePlayer(items: items)
        player = queue
        currentClipName = queuedNames.first
        observeItemEnds(items)
        observeInterruptions()
        queue.play()
        state = .playing
    }

    func togglePlayPause() {
        guard let player else { return }
        switch state {
        case .playing:
            player.pause()
            state = .paused
        case .paused:
            player.play()
            state = .playing
        case .idle, .finished:
            break
        }
    }

    /// Stop and release the session (finished-state reset). Idempotent.
    func stop() {
        teardownPlayer()
        state = .idle
        currentClipName = nil
        deactivateSession()
    }

    // MARK: - Internals

    private func observeItemEnds(_ items: [AVPlayerItem]) {
        for (index, item) in items.enumerated() {
            let token = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.itemDidFinish(index: index) }
            }
            endObservers.append(token)
        }
    }

    private func itemDidFinish(index: Int) {
        // Advance the highlight; the last item finishing means the whole queue is done.
        if index + 1 < queuedNames.count {
            currentClipName = queuedNames[index + 1]
        } else {
            teardownPlayer()
            state = .finished
            currentClipName = nil
            deactivateSession()
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { @Sendable [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let typeValue,
                      AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
                // A phone call/Siri interrupts playback: stop and release the session (KTD11).
                self.stop()
            }
        }
    }

    private func teardownPlayer() {
        player?.pause()
        player = nil
        queuedNames = []
        for token in endObservers { NotificationCenter.default.removeObserver(token) }
        endObservers.removeAll()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    /// Release the audio session through the single owner, honoring the record-epoch guard so
    /// a stale playback deactivation never kills a newer recording (KTD11). No STT teardown.
    private func deactivateSession() {
        Task { [audioSession] in
            await audioSession.end {}
        }
    }
}
