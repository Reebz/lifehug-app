import Foundation
import os

/// A pending re-transcription for one empty/failed voice segment (U5/KTD10). Keyed by clip
/// filename — the stable, persistent identity (the in-memory turn UUID is not).
struct TranscriptionRetryJob: Codable, Equatable {
    let questionID: String
    let clipFilename: String
    var attempts: Int = 0
    var status: Status = .pending

    enum Status: String, Codable {
        case pending          // eligible for automatic drain
        case needsAttention   // attempts exhausted; only a manual retry revives it
    }
}

/// Durable, idempotent retry queue for empty-transcript recovery (R3/F2). Pure list
/// operations are here so idempotency, attempt-bounding, and the needs-attention transition
/// are directly unit-testable; file I/O lives in `TranscriptionRetryStore`.
struct TranscriptionRetryQueue: Codable, Equatable {
    static let maxAttempts = 3
    var jobs: [TranscriptionRetryJob] = []

    /// Idempotent by clip key: re-enqueuing an existing clip is a no-op (never duplicates).
    mutating func enqueue(_ job: TranscriptionRetryJob) {
        guard !jobs.contains(where: { $0.clipFilename == job.clipFilename }) else { return }
        jobs.append(job)
    }

    mutating func remove(clipFilename: String) {
        jobs.removeAll { $0.clipFilename == clipFilename }
    }

    /// Record a failed attempt; at the cap the job moves to needs-attention and stops
    /// auto-retrying. A manual retry revives it via `resetForManualRetry`.
    mutating func recordFailure(clipFilename: String) {
        guard let idx = jobs.firstIndex(where: { $0.clipFilename == clipFilename }) else { return }
        jobs[idx].attempts += 1
        if jobs[idx].attempts >= Self.maxAttempts {
            jobs[idx].status = .needsAttention
        }
    }

    mutating func resetForManualRetry(clipFilename: String) {
        guard let idx = jobs.firstIndex(where: { $0.clipFilename == clipFilename }) else { return }
        jobs[idx].attempts = 0
        jobs[idx].status = .pending
    }

    /// Jobs eligible for an automatic drain (still pending, under the cap).
    var pendingJobs: [TranscriptionRetryJob] {
        jobs.filter { $0.status == .pending }
    }
}

/// Loads/saves the retry queue durably (KTD3/KTD10). Corruption is treated as an empty queue
/// (never a crash), matching the app's lenient read-path convention.
struct TranscriptionRetryStore {
    let storage: StorageService
    /// Filename in Application Support. Overridable so parallel tests isolate their queue.
    let filename: String
    private static let logger = Logger(subsystem: "com.lifehug.app", category: "RetryQueue")

    init(storage: StorageService, filename: String = "transcription-retry-queue.json") {
        self.storage = storage
        self.filename = filename
    }

    var queueURL: URL {
        storage.appSupportDirectory.appendingPathComponent(filename)
    }

    func load() -> TranscriptionRetryQueue {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return TranscriptionRetryQueue() }
        do {
            let data = try Data(contentsOf: queueURL)
            return try JSONDecoder().decode(TranscriptionRetryQueue.self, from: data)
        } catch {
            Self.logger.warning("Retry queue read failed, treating as empty: \(error.localizedDescription)")
            return TranscriptionRetryQueue()
        }
    }

    func save(_ queue: TranscriptionRetryQueue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(queue)
        try storage.durableWrite(
            data,
            to: queueURL,
            protection: .complete,
            excludeFromBackup: !StorageService.iCloudBackupEnabled
        )
    }
}

extension Answer {
    /// Apply a recovered transcription to the segment for `clipFilename`, but only if it is
    /// still flagged needs-transcription and not user-edited (KTD8). Returns the updated
    /// answer, or nil if nothing changed (already filled, edited, empty text, or no such
    /// segment). Rebuilds the answer body from segments so recovered text appears.
    func applyingTranscription(_ text: String, toClip clipFilename: String) -> Answer? {
        guard let idx = segments.firstIndex(where: { $0.clipFilename == clipFilename }),
              segments[idx].needsTranscription,
              !segments[idx].isEdited else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var newSegments = segments
        newSegments[idx].text = trimmed
        newSegments[idx].needsTranscription = false
        let newBody = newSegments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")

        return Answer(
            questionID: questionID, questionText: questionText, categoryLetter: categoryLetter,
            categoryName: categoryName, passNumber: passNumber, askedDate: askedDate,
            answeredDate: answeredDate, answerText: newBody, followUpQuestions: followUpQuestions,
            source: source, segments: newSegments
        )
    }
}

/// Orchestrates empty-transcript recovery (device-only re-transcription). Rebuilds the queue
/// from answers, drains pending jobs on launch, and services manual retries from the browser.
@MainActor
final class TranscriptionRetryCoordinator {
    private let storage: StorageService
    private let stt: STTService
    private let store: TranscriptionRetryStore
    private static let logger = Logger(subsystem: "com.lifehug.app", category: "RetryQueue")

    init(storage: StorageService, stt: STTService) {
        self.storage = storage
        self.stt = stt
        self.store = TranscriptionRetryStore(storage: storage)
    }

    /// Rebuild the queue from every answer's still-flagged segments (idempotent), so recovery
    /// self-heals even if a save-time enqueue was missed, and drops jobs whose segment has
    /// since been filled, edited, or deleted.
    func syncFromAnswers() {
        var queue = store.load()
        let answers = (try? storage.listAnswerFiles())?.compactMap { try? storage.readAnswer(at: $0) } ?? []
        for answer in answers {
            for seg in answer.segments where seg.needsTranscription && !seg.isEdited {
                guard let clip = seg.clipFilename else { continue }
                queue.enqueue(TranscriptionRetryJob(questionID: answer.questionID, clipFilename: clip))
            }
        }
        queue.jobs.removeAll { job in
            guard let answer = answers.first(where: { $0.questionID == job.questionID }),
                  let seg = answer.segments.first(where: { $0.clipFilename == job.clipFilename })
            else { return true }  // answer/segment gone → drop
            return !seg.needsTranscription || seg.isEdited
        }
        try? store.save(queue)
    }

    /// Drain all pending jobs (launch replay). Device-only: requires the ASR model loaded.
    func drainPending() async {
        guard stt.isASRReady else { return }
        for job in store.load().pendingJobs {
            await attempt(clipFilename: job.clipFilename, questionID: job.questionID)
        }
    }

    /// Manual retry from the browser: reset the bounded counter and re-attempt now. Loads the
    /// model first if needed so the button never silently no-ops.
    func manualRetry(clipFilename: String, questionID: String) async {
        if !stt.isASRReady { await stt.loadASRModel() }
        guard stt.isASRReady else { return }
        mutateQueue { queue in
            if queue.jobs.first(where: { $0.clipFilename == clipFilename }) == nil {
                queue.enqueue(TranscriptionRetryJob(questionID: questionID, clipFilename: clipFilename))
            }
            queue.resetForManualRetry(clipFilename: clipFilename)
        }
        await attempt(clipFilename: clipFilename, questionID: questionID)
    }

    /// One re-transcription attempt. All awaits (transcription, answer read) happen WITHOUT
    /// holding the queue; the queue is only ever load-mutate-saved synchronously via
    /// `mutateQueue`, so a concurrent drain and manual retry can't clobber each other's state
    /// across a suspension point.
    private func attempt(clipFilename: String, questionID: String) async {
        // Bad key or missing clip → dead-letter (drop) without crashing.
        guard let clipURL = try? storage.clipURL(filename: clipFilename),
              AudioClipStore.clipExists(at: clipURL) else {
            mutateQueue { $0.remove(clipFilename: clipFilename) }
            return
        }

        guard let text = await stt.transcribeClip(atPath: clipURL.path),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            mutateQueue { $0.recordFailure(clipFilename: clipFilename) }
            return
        }

        // Fill only if still flagged (not edited/filled/deleted meanwhile), then save + dequeue.
        guard let url = try? storage.answerURL(questionID: questionID),
              let answer = try? storage.readAnswer(at: url),
              let updated = answer.applyingTranscription(text, toClip: clipFilename) else {
            mutateQueue { $0.remove(clipFilename: clipFilename) }
            return
        }
        do {
            try storage.saveAnswer(updated)
            mutateQueue { $0.remove(clipFilename: clipFilename) }
            Self.logger.info("Recovered transcription for a flagged segment")
        } catch {
            mutateQueue { $0.recordFailure(clipFilename: clipFilename) }
        }
    }

    /// Atomic load-mutate-save with no `await` between load and save (all on the MainActor).
    private func mutateQueue(_ transform: (inout TranscriptionRetryQueue) -> Void) {
        var queue = store.load()
        transform(&queue)
        try? store.save(queue)
    }
}
