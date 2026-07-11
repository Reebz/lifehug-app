import Testing
import Foundation
@testable import Lifehug

@Suite("ChapterGenerator", .serialized)
struct ChapterGeneratorTests {

    private func answer(id: String, segments: [Answer.Segment]) -> Answer {
        Answer(
            questionID: id, questionText: "Q", categoryLetter: id.first!, categoryName: "C",
            passNumber: 1, askedDate: Date(), answeredDate: Date(),
            answerText: segments.map(\.text).joined(separator: "\n\n"),
            followUpQuestions: [], source: .voice, segments: segments
        )
    }

    // MARK: - Budgeted raw text (KTD14)

    @Test("Budgeted raw text picks voice non-edited segments and respects the cap")
    func budgetedRawText() {
        let a = answer(id: "A1", segments: [
            .init(text: "Spoken one about the farm.", clipFilename: "A1-x-0.m4a", source: .voice),
            .init(text: "Typed addition ignored.", clipFilename: nil, source: .text),
            .init(text: "Edited spoken excluded.", clipFilename: "A1-x-2.m4a", source: .voice, isEdited: true),
            .init(text: "Second spoken about the barn.", clipFilename: "A1-x-3.m4a", source: .voice),
        ])
        let full = ChapterGenerator.budgetedRawText(from: [a], budget: 1000)
        #expect(full.contains("Spoken one about the farm."))
        #expect(full.contains("Second spoken about the barn."))
        #expect(!full.contains("Typed addition"))
        #expect(!full.contains("Edited spoken"))

        let tiny = ChapterGenerator.budgetedRawText(from: [a], budget: 20)
        #expect(tiny.count <= 20)  // first segment already exceeds the cap → nothing added
    }

    // MARK: - Provenance computation (KTD12)

    @Test("Provenance links a matching passage with an exact pull-quote, omits an unmatched one")
    func provenanceLinksAndOmits() {
        let segments = [
            ChapterGenerator.SourceSegment(
                questionID: "A1", segmentIndex: 0,
                text: "I grew up on a dairy farm in Vermont.", clipFilename: "A1-x-0.m4a", isEdited: false
            )
        ]
        let draft = """
        I grew up on a dairy farm in Vermont. Those mornings were cold.

        This paragraph is entirely unrelated boilerplate about nothing at all.
        """
        let prov = ChapterGenerator.computeProvenance(draft: draft, segments: segments, categoryLetter: "A")
        #expect(prov.passages.count == 2)
        #expect(!prov.passages[0].links.isEmpty)
        #expect(prov.passages[0].links.first?.matchStatus == .exact)
        #expect(prov.passages[0].pullQuotes.contains { $0.contains("dairy farm in Vermont") })
        #expect(prov.passages[1].links.isEmpty)
    }

    @Test("Edited segments contribute a link but no verbatim pull-quotes")
    func editedNoQuotes() {
        let segments = [
            ChapterGenerator.SourceSegment(
                questionID: "A1", segmentIndex: 0,
                text: "The old oak tree stood by the gate.", clipFilename: "A1-x-0.m4a", isEdited: true
            )
        ]
        let draft = "The old oak tree stood by the gate. It was ancient."
        let prov = ChapterGenerator.computeProvenance(draft: draft, segments: segments, categoryLetter: "A")
        #expect(prov.passages[0].pullQuotes.isEmpty)
    }

    @Test("Text-only answers compute without crashing")
    func textOnlyProvenance() {
        let segments = [
            ChapterGenerator.SourceSegment(
                questionID: "A1", segmentIndex: 0, text: "A typed answer.", clipFilename: nil, isEdited: false
            )
        ]
        let prov = ChapterGenerator.computeProvenance(draft: "Some unrelated prose.", segments: segments, categoryLetter: "A")
        #expect(prov.passages.count == 1)
    }

    // MARK: - Sidecar persistence (KTD13)

    private func sampleProvenance(letter: String, clip: String) -> ChapterProvenance {
        ChapterProvenance(schemaVersion: 1, categoryLetter: letter, passages: [
            .init(id: "p0", text: "a paragraph", links: [
                .init(
                    questionID: "\(letter)1", clipFilename: clip, segmentIndex: 0,
                    matchStatus: .exact, quote: .init(exact: "a paragraph", prefix: "", suffix: ""),
                    position: .init(start: 0, end: 11), sourceHash: "hash", score: 1.0, pullQuotes: ["a paragraph"]
                )
            ])
        ])
    }

    @Test("Sidecar round-trips and regeneration overwrites it")
    func sidecarRoundtrip() throws {
        let storage = StorageService()
        let letter: Character = "Z"
        defer { try? FileManager.default.removeItem(at: storage.provenanceURL(categoryLetter: letter)) }

        let prov = sampleProvenance(letter: "Z", clip: "Z1-x-0.m4a")
        try storage.saveProvenance(prov)
        #expect(storage.readProvenance(categoryLetter: letter) == prov)

        try storage.saveProvenance(ChapterProvenance(schemaVersion: 1, categoryLetter: "Z", passages: []))
        #expect(storage.readProvenance(categoryLetter: letter)?.passages.isEmpty == true)
    }

    @Test("Deleting a clip prunes its provenance links")
    func prunesDeletedClipLinks() throws {
        let storage = StorageService()
        let letter: Character = "Y"
        defer { try? FileManager.default.removeItem(at: storage.provenanceURL(categoryLetter: letter)) }

        let clip = "Y1-\(UUID().uuidString)-0.m4a"
        try storage.saveProvenance(sampleProvenance(letter: "Y", clip: clip))
        storage.pruneProvenanceSidecars(deletedClips: [clip])
        #expect(storage.readProvenance(categoryLetter: letter)?.passages.first?.links.isEmpty == true)
    }

    @Test("Deleting an answer prunes provenance links from its text segments too")
    func prunesByAnswerID() throws {
        let storage = StorageService()
        let letter: Character = "W"
        defer { try? FileManager.default.removeItem(at: storage.provenanceURL(categoryLetter: letter)) }

        // A link from a TEXT segment (no clip) — only answer-id pruning can reach it.
        let prov = ChapterProvenance(schemaVersion: 1, categoryLetter: "W", passages: [
            .init(id: "p0", text: "p", links: [
                .init(
                    questionID: "W1", clipFilename: nil, segmentIndex: 0, matchStatus: .exact,
                    quote: .init(exact: "", prefix: "", suffix: ""), position: .init(start: 0, end: 0),
                    sourceHash: "h", score: 1, pullQuotes: ["q"]
                )
            ])
        ])
        try storage.saveProvenance(prov)
        storage.pruneProvenanceSidecars(deletedAnswerID: "W1")
        #expect(storage.readProvenance(categoryLetter: letter)?.passages.first?.links.isEmpty == true)
    }
}
