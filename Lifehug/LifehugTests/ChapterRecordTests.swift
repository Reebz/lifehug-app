import Testing
import Foundation
@testable import Lifehug

@Suite("ChapterRecord", .serialized)
struct ChapterRecordTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Begin review seeds passages unresolved and moves to in-review")
    func beginReview() {
        var record = ChapterRecord.newDraft(categoryLetter: "A", now: now)
        record.beginReview(passageIDs: ["p0", "p1"], now: now)
        #expect(record.status == .inReview)
        #expect(record.passages.count == 2)
        #expect(record.passages.allSatisfy { $0.state == .unresolved })
        #expect(!record.allResolved)
    }

    @Test("Ratify is blocked until every passage is resolved")
    func ratifyBlocked() {
        var record = ChapterRecord.newDraft(categoryLetter: "A", now: now)
        record.beginReview(passageIDs: ["p0", "p1"], now: now)
        record.resolve(passageID: "p0", state: .approved, now: now)
        #expect(record.ratify(now: now) == false)
        #expect(record.status == .inReview)

        record.resolve(passageID: "p1", state: .rejected, now: now)
        #expect(record.allResolved)
        #expect(record.ratify(now: now) == true)
        #expect(record.status == .ratified)
    }

    @Test("Regeneration resets approvals and returns to draft")
    func regenReset() {
        var record = ChapterRecord.newDraft(categoryLetter: "A", now: now)
        record.beginReview(passageIDs: ["p0"], now: now)
        record.resolve(passageID: "p0", state: .approved, now: now)
        _ = record.ratify(now: now)
        #expect(record.hasAnyApproval)

        record.resetForRegeneration(newPassageIDs: ["p0", "p1"], now: now)
        #expect(record.status == .draft)
        #expect(record.passages.count == 2)
        #expect(!record.hasAnyApproval)
        #expect(record.passages.allSatisfy { $0.state == .unresolved })
    }

    @Test("Request-change stores a note; switching to another state clears it")
    func changeNote() {
        var record = ChapterRecord.newDraft(categoryLetter: "A", now: now)
        record.beginReview(passageIDs: ["p0"], now: now)
        record.resolve(passageID: "p0", state: .changeRequested, note: "tighten this", now: now)
        #expect(record.passages[0].note == "tighten this")
        record.resolve(passageID: "p0", state: .approved, note: "tighten this", now: now)
        #expect(record.passages[0].note == "")
    }

    @Test("Record round-trips through storage")
    func roundtrip() throws {
        let storage = StorageService()
        let letter: Character = "X"
        defer { try? FileManager.default.removeItem(at: storage.chapterRecordURL(categoryLetter: letter)) }

        var record = ChapterRecord.newDraft(categoryLetter: "X", now: now)
        record.beginReview(passageIDs: ["p0", "p1"], now: now)
        record.resolve(passageID: "p0", state: .approved, now: now)
        try storage.saveChapterRecord(record)
        #expect(storage.readChapterRecord(categoryLetter: letter) == record)
    }

    @Test("A missing record reads as nil (an interim draft has none)")
    func missingRecordNil() {
        let storage = StorageService()
        try? FileManager.default.removeItem(at: storage.chapterRecordURL(categoryLetter: "W"))
        #expect(storage.readChapterRecord(categoryLetter: "W") == nil)
    }
}
