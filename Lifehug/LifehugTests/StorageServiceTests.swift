import Testing
import Foundation
@testable import Lifehug

@Suite("StorageService", .serialized)
struct StorageServiceTests {

    // StorageService uses system directories (Application Support, Documents) that
    // cannot be redirected without an init parameter. These tests exercise the
    // read-path logic (missing file, corrupted file) and the saveAnswer regex guard
    // by working against temporary files directly and calling the service on a
    // real instance whose directories exist in the simulator/test sandbox.

    private let storage = StorageService()

    // MARK: - Rotation State

    @Test("Read rotation state from missing file returns default")
    func readRotationStateMissingFile() {
        // Delete any existing rotation file so we test the missing-file path.
        let url = storage.rotationURL
        try? FileManager.default.removeItem(at: url)

        let state = storage.readRotationState()

        #expect(state.version == 1)
        #expect(state.questionsAsked == 0)
        #expect(state.lastQuestionID == nil)
        #expect(state.spotlightFrequency == 4)
    }

    @Test("Read rotation state from corrupted file returns default")
    func readRotationStateCorruptedFile() throws {
        let url = storage.rotationURL
        // Ensure the parent directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write garbage data
        try "not json at all {{{".data(using: .utf8)!
            .write(to: url, options: .atomic)

        let state = storage.readRotationState()

        #expect(state.version == 1)
        #expect(state.questionsAsked == 0)
        #expect(state.lastQuestionID == nil)

        // Clean up
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Config

    @Test("Read config from missing file returns default")
    func readConfigMissingFile() {
        let url = storage.configURL
        try? FileManager.default.removeItem(at: url)

        let config = storage.readConfig()

        #expect(config.name == "friend")
        #expect(config.projects.isEmpty)
    }

    @Test("Read config from corrupted file returns default")
    func readConfigCorruptedFile() throws {
        let url = storage.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "<<<broken>>>".data(using: .utf8)!
            .write(to: url, options: .atomic)

        let config = storage.readConfig()

        #expect(config.name == "friend")
        #expect(config.projects.isEmpty)

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Save Answer (regex guard)

    @Test("Save answer with valid ID writes file")
    func saveAnswerValidID() throws {
        let answer = Answer(
            questionID: "A1",
            questionText: "What's your earliest memory?",
            categoryLetter: "A",
            categoryName: "Origins",
            passNumber: 1,
            askedDate: Date(),
            answeredDate: Date(),
            answerText: "I remember the garden.",
            followUpQuestions: [],
            source: .text
        )

        try storage.saveAnswer(answer)

        let expectedURL = storage.answersDirectory.appendingPathComponent("A1.md")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))

        // Clean up
        try? FileManager.default.removeItem(at: expectedURL)
    }

    @Test("Save answer with invalid ID does not write — path traversal guard")
    func saveAnswerInvalidID() throws {
        let answer = Answer(
            questionID: "../etc/passwd",
            questionText: "Malicious",
            categoryLetter: ".",
            categoryName: "Evil",
            passNumber: 1,
            askedDate: Date(),
            answeredDate: Date(),
            answerText: "Should not be saved.",
            followUpQuestions: [],
            source: .text
        )

        // saveAnswer silently returns on invalid IDs (no throw)
        try storage.saveAnswer(answer)

        let badURL = storage.answersDirectory.appendingPathComponent("../etc/passwd.md")
        #expect(!FileManager.default.fileExists(atPath: badURL.path))
    }

    @Test("Save answer with lowercase ID does not write")
    func saveAnswerLowercaseID() throws {
        let answer = Answer(
            questionID: "a1",
            questionText: "Lowercase attempt",
            categoryLetter: "a",
            categoryName: "Test",
            passNumber: 1,
            askedDate: Date(),
            answeredDate: Date(),
            answerText: "Should not be saved.",
            followUpQuestions: [],
            source: .text
        )

        try storage.saveAnswer(answer)

        let url = storage.answersDirectory.appendingPathComponent("a1.md")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Save answer with multi-letter category ID does not write")
    func saveAnswerMultiLetterID() throws {
        let answer = Answer(
            questionID: "AB1",
            questionText: "Multi-letter category",
            categoryLetter: "A",
            categoryName: "Test",
            passNumber: 1,
            askedDate: Date(),
            answeredDate: Date(),
            answerText: "Should not be saved.",
            followUpQuestions: [],
            source: .text
        )

        try storage.saveAnswer(answer)

        let url = storage.answersDirectory.appendingPathComponent("AB1.md")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Durable Write (U1)

    @Test("Durable write creates file with content, protection, and backup exclusion")
    func durableWriteAttributes() throws {
        let url = storage.clipsDirectory.appendingPathComponent("durable-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data("durable payload".utf8)

        try storage.durableWrite(payload, to: url, protection: .completeUnlessOpen, excludeFromBackup: true)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == payload)

        // File protection is enforced/reported on device only — the simulator sandbox
        // returns nil for `.protectionKey` (the plan's separate device-capture gate covers
        // it). Assert the value only when the platform reports it, so a wrong class is
        // still caught on device without failing the simulator CI gate.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let protection = attrs[.protectionKey] as? FileProtectionType {
            #expect(protection == .completeUnlessOpen)
        }

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Durable write overwrite replaces content atomically")
    func durableWriteOverwrite() throws {
        let url = storage.clipsDirectory.appendingPathComponent("overwrite-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        try storage.durableWrite(Data("first".utf8), to: url, protection: .complete, excludeFromBackup: false)
        #expect(try Data(contentsOf: url) == Data("first".utf8))

        try storage.durableWrite(Data("second-longer".utf8), to: url, protection: .complete, excludeFromBackup: false)
        #expect(try Data(contentsOf: url) == Data("second-longer".utf8))

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == false)
    }

    @Test("Durable place consumes the temp file and lands the destination")
    func durablePlaceMovesTemp() throws {
        let temp = storage.clipsStagingDirectory.appendingPathComponent("src-\(UUID().uuidString).tmp")
        let dest = storage.clipsDirectory.appendingPathComponent("dest-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: temp)
        }
        try Data("clip bytes".utf8).write(to: temp)

        try storage.durablePlace(tempFile: temp, at: dest, protection: .completeUnlessOpen, excludeFromBackup: true)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))  // consumed by the rename
        #expect(try Data(contentsOf: dest) == Data("clip bytes".utf8))
    }

    // MARK: - Clip Key Validation (U1)

    @Test("Invalid clip key throws")
    func invalidClipKeyThrows() {
        #expect(throws: StorageError.self) {
            _ = try storage.clipURL(filename: "../evil.m4a")
        }
        #expect(throws: StorageError.self) {
            _ = try storage.clipURL(filename: "A1.m4a")  // missing uuid + turn index
        }
    }

    @Test("Valid clip key resolves under the clips directory")
    func validClipKeyResolves() throws {
        let name = "A1-\(UUID().uuidString)-0.m4a"
        let url = try storage.clipURL(filename: name)
        #expect(url.deletingLastPathComponent().lastPathComponent == "clips")
        #expect(url.lastPathComponent == name)
    }

    @Test("Clip filename validation accepts KTD7 format, rejects traversal")
    func clipFilenameValidation() {
        let uuid = UUID().uuidString
        #expect(StorageService.isValidClipFilename("A1-\(uuid)-0.m4a"))
        #expect(StorageService.isValidClipFilename("K12-\(uuid)-3.m4a"))
        #expect(!StorageService.isValidClipFilename("a1-\(uuid)-0.m4a"))   // lowercase category
        #expect(!StorageService.isValidClipFilename("A1-\(uuid)-0.wav"))   // wrong extension
        #expect(!StorageService.isValidClipFilename("A1/\(uuid)-0.m4a"))   // path separator
        #expect(!StorageService.isValidClipFilename("../\(uuid).m4a"))
    }

    @Test("Clips directories are created and (on device) protected after setup")
    func clipsDirectoriesProtectedAfterSetup() throws {
        try storage.setupDirectories()
        for dir in [storage.clipsDirectory, storage.clipsStagingDirectory] {
            #expect(FileManager.default.fileExists(atPath: dir.path))
            // Protection class is device-only reported (see durableWriteAttributes).
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen)
            }
        }
    }

    // MARK: - Delete & Reconciliation (U7)

    private func writeClip(_ name: String, to dir: URL, bytes: Int = 32) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(repeating: 0xAB, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    private func voiceAnswer(id: String, segments: [Answer.Segment]) -> Answer {
        Answer(
            questionID: id, questionText: "Q", categoryLetter: id.first!, categoryName: "C",
            passNumber: 1, askedDate: Date(), answeredDate: Date(),
            answerText: segments.map(\.text).joined(separator: "\n\n"),
            followUpQuestions: [], source: .voice, segments: segments
        )
    }

    @Test("Delete answer removes its markdown and clips")
    func deleteAnswerRemovesAll() throws {
        let clip = "Q1-\(UUID().uuidString)-0.m4a"
        writeClip(clip, to: storage.clipsDirectory)
        let answer = voiceAnswer(id: "Q1", segments: [.init(text: "hi", clipFilename: clip, source: .voice)])
        try storage.saveAnswer(answer)
        let mdPath = try storage.answerURL(questionID: "Q1").path
        #expect(FileManager.default.fileExists(atPath: mdPath))

        try storage.deleteAnswer(answer)
        #expect(!FileManager.default.fileExists(atPath: mdPath))
        #expect(!FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(clip).path))
    }

    @Test("Audio-only delete keeps the text and clears clip refs")
    func deleteAudioKeepsText() throws {
        let clip = "R1-\(UUID().uuidString)-0.m4a"
        writeClip(clip, to: storage.clipsDirectory)
        let answer = voiceAnswer(id: "R1", segments: [.init(text: "kept text", clipFilename: clip, source: .voice)])
        try storage.saveAnswer(answer)
        defer { try? FileManager.default.removeItem(at: try! storage.answerURL(questionID: "R1")) }

        let updated = try storage.deleteAudio(for: answer)
        #expect(!FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(clip).path))
        #expect(updated.segments[0].clipFilename == nil)
        #expect(updated.segments[0].text == "kept text")
        // Re-read from disk to confirm the cleared ref persisted.
        let reread = try storage.readAnswer(at: try storage.answerURL(questionID: "R1"))
        #expect(reread?.segments.first?.clipFilename == nil)
    }

    @Test("Re-answer deletes prior clips the new answer no longer references")
    func deletePriorClipsReplacesSet() {
        let old = "S1-\(UUID().uuidString)-0.m4a"
        let new = "S1-\(UUID().uuidString)-0.m4a"
        writeClip(old, to: storage.clipsDirectory)
        writeClip(new, to: storage.clipsDirectory)

        storage.deletePriorClips([old], keeping: [new])
        #expect(!FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(old).path))
        #expect(FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(new).path))
        try? FileManager.default.removeItem(at: storage.clipsDirectory.appendingPathComponent(new))
    }

    @Test("Reconcile removes a zero-byte fragment and keeps a real orphan, counted")
    func reconcileFragmentsAndOrphans() throws {
        let fragment = "frag-\(UUID().uuidString).tmp"   // invalid clip name → fragment
        let orphan = "T1-\(UUID().uuidString)-0.m4a"      // valid, unreferenced → orphan
        writeClip(fragment, to: storage.clipsDirectory)
        writeClip(orphan, to: storage.clipsDirectory)
        defer { try? FileManager.default.removeItem(at: storage.clipsDirectory.appendingPathComponent(orphan)) }

        let report = storage.reconcileClipStorage()
        #expect(!FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(fragment).path))
        #expect(FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(orphan).path))
        #expect(report.orphanedClips >= 1)
    }

    @Test("Reconcile clears a segment whose clip is missing")
    func reconcileMissingClipRef() throws {
        let missing = "U1-\(UUID().uuidString)-0.m4a"  // referenced but never written
        let answer = voiceAnswer(id: "U1", segments: [.init(text: "orphan text", clipFilename: missing, source: .voice)])
        try storage.saveAnswer(answer)
        defer { try? FileManager.default.removeItem(at: try! storage.answerURL(questionID: "U1")) }

        _ = storage.reconcileClipStorage()
        let reread = try storage.readAnswer(at: try storage.answerURL(questionID: "U1"))
        #expect(reread?.segments.first?.clipFilename == nil)
        #expect(reread?.segments.first?.text == "orphan text")
    }

    @Test("Reconcile removes abandoned staging but spares the protected session")
    func reconcileStaging() throws {
        let protectedSession = UUID().uuidString
        let abandonedSession = UUID().uuidString
        let protectedDir = storage.clipsStagingDirectory.appendingPathComponent(protectedSession, isDirectory: true)
        let abandonedDir = storage.clipsStagingDirectory.appendingPathComponent(abandonedSession, isDirectory: true)
        writeClip("A1-\(UUID().uuidString)-0.m4a", to: protectedDir)
        writeClip("A1-\(UUID().uuidString)-0.m4a", to: abandonedDir)
        defer { try? FileManager.default.removeItem(at: protectedDir) }

        _ = storage.reconcileClipStorage(protectingStagingSession: protectedSession)
        #expect(FileManager.default.fileExists(atPath: protectedDir.path))
        #expect(!FileManager.default.fileExists(atPath: abandonedDir.path))
    }

    @Test("Commit recovers a raw dump whose encode never produced an m4a")
    func commitRecoversRawDump() throws {
        let session = UUID().uuidString
        let clip = "P1-\(UUID().uuidString)-0.m4a"
        let stagingDir = storage.clipsStagingDirectory.appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let samples = (0..<16_000).map { Float(0.1 * sin(Double($0) * 0.05)) }
        try AudioClipStore.writeRawDump(samples, to: stagingDir.appendingPathComponent(clip + ".raw"))
        defer {
            try? FileManager.default.removeItem(at: storage.clipsDirectory.appendingPathComponent(clip))
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let committed = storage.commitClips(recordingSessionID: session)
        #expect(committed.contains(clip))
        #expect(FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(clip).path))
    }

    @Test("Saving commits real clips and clears refs to clips that never committed")
    func saveCommitsAndClearsDangling() throws {
        let session = UUID().uuidString
        let realClip = "P2-\(UUID().uuidString)-0.m4a"
        let ghostClip = "P2-\(UUID().uuidString)-1.m4a"  // referenced but never staged
        let stagingDir = storage.clipsStagingDirectory.appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let samples = (0..<16_000).map { Float(0.1 * sin(Double($0) * 0.05)) }
        try AudioClipStore.encode(samples: samples, to: stagingDir.appendingPathComponent(realClip))
        let answer = voiceAnswer(id: "P2", segments: [
            .init(text: "real", clipFilename: realClip, source: .voice),
            .init(text: "ghost", clipFilename: ghostClip, source: .voice),
        ])
        defer {
            try? FileManager.default.removeItem(at: try! storage.answerURL(questionID: "P2"))
            try? FileManager.default.removeItem(at: storage.clipsDirectory.appendingPathComponent(realClip))
        }

        let saved = try storage.saveAnswerCommittingClips(answer, recordingSessionID: session)
        #expect(saved.segments[0].clipFilename == realClip)  // committed
        #expect(saved.segments[1].clipFilename == nil)        // ghost cleared
        #expect(FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(realClip).path))
    }

    @Test("Reconcile is idempotent across two runs")
    func reconcileIdempotent() throws {
        let orphan = "V1-\(UUID().uuidString)-0.m4a"
        writeClip(orphan, to: storage.clipsDirectory)
        defer { try? FileManager.default.removeItem(at: storage.clipsDirectory.appendingPathComponent(orphan)) }

        let first = storage.reconcileClipStorage()
        let second = storage.reconcileClipStorage()
        #expect(first.orphanedClips >= 1)
        #expect(second.orphanedClips >= 1)
        #expect(FileManager.default.fileExists(atPath: storage.clipsDirectory.appendingPathComponent(orphan).path))
    }
}
