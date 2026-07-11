import Testing
import Foundation
@testable import Lifehug

@Suite("TranscriptionRetryQueue")
struct TranscriptionRetryQueueTests {

    private func job(_ clip: String, questionID: String = "A1") -> TranscriptionRetryJob {
        TranscriptionRetryJob(questionID: questionID, clipFilename: clip)
    }

    // MARK: - Queue operations (pure)

    @Test("Enqueue is idempotent by clip key")
    func enqueueIdempotent() {
        var queue = TranscriptionRetryQueue()
        queue.enqueue(job("A1-x-0.m4a"))
        queue.enqueue(job("A1-x-0.m4a"))  // same clip → no duplicate
        queue.enqueue(job("A1-x-1.m4a"))
        #expect(queue.jobs.count == 2)
    }

    @Test("Attempt cap moves a job to needs-attention and out of pending")
    func attemptCapNeedsAttention() {
        var queue = TranscriptionRetryQueue()
        queue.enqueue(job("A1-x-0.m4a"))
        for _ in 0..<TranscriptionRetryQueue.maxAttempts {
            queue.recordFailure(clipFilename: "A1-x-0.m4a")
        }
        #expect(queue.jobs[0].status == .needsAttention)
        #expect(queue.pendingJobs.isEmpty)
    }

    @Test("Manual retry resets attempts and status")
    func manualRetryResets() {
        var queue = TranscriptionRetryQueue()
        queue.enqueue(job("A1-x-0.m4a"))
        for _ in 0..<TranscriptionRetryQueue.maxAttempts {
            queue.recordFailure(clipFilename: "A1-x-0.m4a")
        }
        queue.resetForManualRetry(clipFilename: "A1-x-0.m4a")
        #expect(queue.jobs[0].attempts == 0)
        #expect(queue.jobs[0].status == .pending)
        #expect(queue.pendingJobs.count == 1)
    }

    @Test("Remove deletes the job by clip key")
    func removeJob() {
        var queue = TranscriptionRetryQueue()
        queue.enqueue(job("A1-x-0.m4a"))
        queue.remove(clipFilename: "A1-x-0.m4a")
        #expect(queue.jobs.isEmpty)
    }

    // MARK: - Store round-trip and corruption

    @Test("Queue survives a relaunch (durable round-trip)")
    func storeRoundtrip() throws {
        let store = TranscriptionRetryStore(storage: StorageService(), filename: "retry-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store.queueURL) }

        var queue = TranscriptionRetryQueue()
        queue.enqueue(job("A1-x-0.m4a"))
        queue.enqueue(job("A2-y-1.m4a", questionID: "A2"))
        try store.save(queue)

        let reloaded = store.load()
        #expect(reloaded == queue)
    }

    @Test("Corrupt queue file is treated as empty, not a crash")
    func corruptQueueEmpty() throws {
        let store = TranscriptionRetryStore(storage: StorageService(), filename: "retry-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store.queueURL) }
        try Data("not json {{{".utf8).write(to: store.queueURL)
        #expect(store.load().jobs.isEmpty)
    }

    @Test("Missing queue file loads as empty")
    func missingQueueEmpty() {
        let store = TranscriptionRetryStore(storage: StorageService(), filename: "retry-test-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: store.queueURL)
        #expect(store.load().jobs.isEmpty)
    }

    // MARK: - Answer transcription fill (pure)

    private func flaggedAnswer() -> Answer {
        Answer(
            questionID: "A1", questionText: "Q", categoryLetter: "A", categoryName: "Origins",
            passNumber: 1, askedDate: Date(), answeredDate: Date(),
            answerText: "First turn.", followUpQuestions: [], source: .voice,
            segments: [
                .init(text: "First turn.", clipFilename: "A1-x-0.m4a", source: .voice),
                .init(text: "", clipFilename: "A1-x-1.m4a", source: .voice, needsTranscription: true),
            ]
        )
    }

    @Test("Recovered text fills a flagged segment and unflags it")
    func fillsFlaggedSegment() {
        let updated = flaggedAnswer().applyingTranscription("Recovered words.", toClip: "A1-x-1.m4a")
        #expect(updated != nil)
        #expect(updated!.segments[1].text == "Recovered words.")
        #expect(updated!.segments[1].needsTranscription == false)
        #expect(updated!.answerText.contains("Recovered words."))
    }

    @Test("Fill skips a segment that is not flagged")
    func skipsUnflagged() {
        let result = flaggedAnswer().applyingTranscription("Nope.", toClip: "A1-x-0.m4a")
        #expect(result == nil)
    }

    @Test("Fill skips a user-edited segment")
    func skipsEdited() {
        var answer = flaggedAnswer()
        var segs = answer.segments
        segs[1].isEdited = true
        answer = answer.replacingSegments(segs)
        #expect(answer.applyingTranscription("Nope.", toClip: "A1-x-1.m4a") == nil)
    }

    @Test("Fill skips empty recovered text")
    func skipsEmptyText() {
        #expect(flaggedAnswer().applyingTranscription("   ", toClip: "A1-x-1.m4a") == nil)
    }

    @Test("Fill returns nil for an unknown clip")
    func unknownClip() {
        #expect(flaggedAnswer().applyingTranscription("Hi.", toClip: "A1-x-9.m4a") == nil)
    }
}
