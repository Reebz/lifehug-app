import Foundation

/// Per-chapter consent record (KTD15): a small persistent state machine gating a chapter's
/// finalization. draft → in-review → ratified, with per-passage resolutions keyed to the
/// provenance passage ids. Interim drafts carry no ratification state (R15); only an explicit
/// finalization walk moves a chapter toward ratified. Pure mutators so the transitions are
/// directly unit-testable (dates are injected, never `Date()` inside).
struct ChapterRecord: Codable, Equatable {
    var categoryLetter: String
    var status: Status = .draft
    var passages: [PassageResolution] = []
    var createdAt: Date
    var updatedAt: Date

    enum Status: String, Codable, Equatable {
        case draft
        case inReview
        case ratified
    }

    struct PassageResolution: Codable, Equatable {
        var passageID: String
        var state: State = .unresolved
        /// Free-text note captured on "request change" — advisory for the author at the next
        /// regeneration, not fed into generation prompts in this plan.
        var note: String = ""

        enum State: String, Codable, Equatable {
            case unresolved
            case approved
            case rejected
            case changeRequested
        }
    }

    /// Every passage has a non-unresolved state (and there is at least one passage).
    var allResolved: Bool {
        !passages.isEmpty && passages.allSatisfy { $0.state != .unresolved }
    }

    /// Any approval exists — the trigger for the regeneration-reset confirmation (KTD15).
    var hasAnyApproval: Bool {
        passages.contains { $0.state == .approved }
    }

    /// A fresh draft record for a newly generated chapter.
    static func newDraft(categoryLetter: Character, now: Date) -> ChapterRecord {
        ChapterRecord(categoryLetter: String(categoryLetter), status: .draft, passages: [], createdAt: now, updatedAt: now)
    }

    /// Begin finalization: seed passage resolutions from the provenance passage ids and move to
    /// in-review, preserving any prior resolution for a passage id that still exists.
    mutating func beginReview(passageIDs: [String], now: Date) {
        let existing = Dictionary(passages.map { ($0.passageID, $0) }, uniquingKeysWith: { first, _ in first })
        passages = passageIDs.map { existing[$0] ?? PassageResolution(passageID: $0) }
        status = .inReview
        updatedAt = now
    }

    mutating func resolve(passageID: String, state: PassageResolution.State, note: String = "", now: Date) {
        guard let idx = passages.firstIndex(where: { $0.passageID == passageID }) else { return }
        passages[idx].state = state
        passages[idx].note = state == .changeRequested ? note : ""
        updatedAt = now
    }

    /// Ratify only when every passage is resolved (KTD15). Returns false (no state change) if
    /// any passage is still unresolved.
    @discardableResult
    mutating func ratify(now: Date) -> Bool {
        guard allResolved else { return false }
        status = .ratified
        updatedAt = now
        return true
    }

    /// Regeneration reset (KTD15): all passages back to unresolved, status back to draft. The
    /// new passage ids come from the freshly recomputed provenance (anchors move with prose).
    mutating func resetForRegeneration(newPassageIDs: [String], now: Date) {
        passages = newPassageIDs.map { PassageResolution(passageID: $0) }
        status = .draft
        updatedAt = now
    }
}
