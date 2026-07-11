import Testing
import Foundation
@testable import Lifehug

@Suite("AudioClipPlayer")
@MainActor
struct AudioClipPlayerTests {

    private func seg(_ clip: String?, _ text: String = "x", voice: Bool = true) -> Answer.Segment {
        Answer.Segment(text: text, clipFilename: clip, source: voice ? .voice : .text)
    }

    @Test("Playable clips preserve order and skip clip-less segments")
    func playableClipsOrder() {
        let segments = [
            seg("A1-x-0.m4a"),
            seg(nil, "typed", voice: false),
            seg("A1-x-2.m4a"),
        ]
        let clips = AudioClipPlayer.playableClips(from: segments) { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(clips.map(\.name) == ["A1-x-0.m4a", "A1-x-2.m4a"])
    }

    @Test("Play is refused while a recording session is live")
    func refusedWhileRecording() {
        let player = AudioClipPlayer(recordingActive: { true })
        player.play([("A1-x-0.m4a", URL(fileURLWithPath: "/tmp/nope.m4a"))])
        #expect(player.state == .idle)
        #expect(player.refusedWhileRecording)
    }

    @Test("An all-missing queue lands in finished")
    func allMissingFinishes() {
        let player = AudioClipPlayer()
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).m4a")
        player.play([("A1-x-0.m4a", url)])
        #expect(player.state == .finished)
        #expect(player.currentClipName == nil)
    }

    @Test("Toggle is a no-op with no active player")
    func toggleIdleNoop() {
        let player = AudioClipPlayer()
        player.togglePlayPause()
        #expect(player.state == .idle)
    }

    @Test("Stop resets to idle")
    func stopResets() {
        let player = AudioClipPlayer()
        player.stop()
        #expect(player.state == .idle)
        #expect(player.currentClipName == nil)
    }
}
