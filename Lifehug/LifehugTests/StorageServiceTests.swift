import Testing
import Foundation
@testable import Lifehug

@Suite("StorageService")
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
}
