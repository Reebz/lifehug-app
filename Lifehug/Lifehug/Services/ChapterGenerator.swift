import Foundation
import os

enum ChapterGenerator {
    enum Pass: String, Sendable {
        case extracting = "Reading your answers..."
        case outlining = "Organizing the story..."
        case writing = "Writing the chapter..."
    }

    private static let logger = Logger(subsystem: "com.lifehug.app", category: "ChapterGenerator")

    /// Generate a chapter using a 3-pass pipeline sized for the smallest model tier.
    ///
    /// Pass 1 (Extract): Pull key facts, moments, emotions as bullet points.
    /// Pass 2 (Outline): Create chapter structure from bullets.
    /// Pass 3 (Flesh out): Write the actual chapter prose.
    @MainActor
    static func generate(
        category: Category,
        answers: [Answer],
        userName: String,
        llmService: LLMService,
        onPassChange: ((Pass) -> Void)? = nil
    ) async throws -> String {
        // Pre-flight memory check
        guard MemoryMonitor.currentPressure < .critical else {
            throw ChapterGeneratorError.insufficientMemory
        }

        // Pass 1: Extract — batch into groups of 10 for large answer sets
        onPassChange?(.extracting)
        let bullets = try await extractBullets(
            category: category,
            answers: answers,
            llmService: llmService
        )
        logger.info("Extract pass complete: \(bullets.count) characters")

        // Re-check memory before pass 2
        guard MemoryMonitor.currentPressure < .critical else {
            throw ChapterGeneratorError.insufficientMemory
        }

        // Pass 2: Outline
        onPassChange?(.outlining)
        let outline = try await buildOutline(
            categoryName: category.name,
            bullets: bullets,
            llmService: llmService
        )
        logger.info("Outline pass complete: \(outline.count) characters")

        // Re-check memory before pass 3
        guard MemoryMonitor.currentPressure < .critical else {
            throw ChapterGeneratorError.insufficientMemory
        }

        // Pass 3: Flesh out. Supplement the bullets with a budgeted slice of the person's
        // actual words (KTD14) so "use their own words" is satisfiable, not aspirational.
        onPassChange?(.writing)
        let rawText = budgetedRawText(from: answers, budget: rawTextBudget)
        let draft = try await writeDraft(
            categoryName: category.name,
            userName: userName,
            outline: outline,
            bullets: bullets,
            rawText: rawText,
            llmService: llmService
        )
        logger.info("Writing pass complete: \(draft.count) characters")

        return draft
    }

    /// Hard character budget for the raw-words supplement in the writing pass — small enough
    /// that the smallest model tier's context window still fits (KTD14).
    static let rawTextBudget = 2000

    enum ChapterGeneratorError: Error, LocalizedError {
        case insufficientMemory

        var errorDescription: String? {
            switch self {
            case .insufficientMemory:
                return "Not enough memory to generate a chapter. Close other apps and try again."
            }
        }
    }

    // MARK: - Pass 1: Extract

    @MainActor
    private static func extractBullets(
        category: Category,
        answers: [Answer],
        llmService: LLMService
    ) async throws -> String {
        let sortedAnswers = answers.sorted { $0.questionID < $1.questionID }

        // Batch into groups of 10 to stay within the smallest model tier's context window
        let batchSize = 10
        var allBullets: [String] = []

        for batchStart in stride(from: 0, to: sortedAnswers.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, sortedAnswers.count)
            let batch = Array(sortedAnswers[batchStart..<batchEnd])

            let answersBlock = batch.map { answer in
                "Q: \(answer.questionText)\nA: \(answer.answerText)"
            }.joined(separator: "\n\n")

            let prompt = """
            Extract the key facts, moments, and emotions from these interview answers \
            about "\(category.name)".
            Return as bullet points. Be specific — include names, places, dates mentioned.

            \(answersBlock)
            """

            let result = try await llmService.generateLongResponse(to: prompt, maxTokens: 500)
            allBullets.append(result)
        }

        return allBullets.joined(separator: "\n")
    }

    // MARK: - Pass 2: Outline

    @MainActor
    private static func buildOutline(
        categoryName: String,
        bullets: String,
        llmService: LLMService
    ) async throws -> String {
        let prompt = """
        Create a brief chapter outline for "\(categoryName)" using these key details:
        \(bullets)
        Structure: opening hook, 2-3 main sections, closing reflection.
        Keep the outline concise — just section titles and 1-line descriptions.
        """

        return try await llmService.generateLongResponse(to: prompt, maxTokens: 300)
    }

    // MARK: - Pass 3: Write

    @MainActor
    private static func writeDraft(
        categoryName: String,
        userName: String,
        outline: String,
        bullets: String,
        rawText: String,
        llmService: LLMService
    ) async throws -> String {
        let ownWords = rawText.isEmpty ? "" : """

        Their exact words (weave in verbatim where it reads naturally; never invent):
        \(rawText)
        """
        let prompt = """
        Write a memoir chapter called "\(categoryName)" for \(userName).
        Follow this outline: \(outline)
        Use these source details: \(bullets)\(ownWords)
        Write in first person. Use \(userName)'s own words where possible.
        Keep it authentic — don't add facts they didn't mention.
        """

        return try await llmService.generateLongResponse(to: prompt, maxTokens: 800)
    }

    // MARK: - Raw-text budgeting (KTD14)

    /// A budgeted concatenation of the person's actual spoken words for the writing pass:
    /// voice, non-edited, non-empty segments in answer order, up to a hard character budget.
    /// Pure so the cap behavior is unit-testable.
    static func budgetedRawText(from answers: [Answer], budget: Int) -> String {
        let segs = answers
            .sorted { $0.questionID < $1.questionID }
            .flatMap(\.segments)
            .filter { $0.source == .voice && !$0.isEdited && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = ""
        for seg in segs {
            let addition = (out.isEmpty ? "" : "\n\n") + seg.text
            if out.count + addition.count > budget { break }
            out += addition
        }
        return out
    }
}

// MARK: - Chapter Provenance (U10 / KTD12–KTD13)

/// Machine-readable provenance sidecar for a chapter: passage → source-segment links with
/// validated verbatim pull-quotes. Schema-versioned and regenerable; the chapter markdown
/// stays headerless prose (the human artifact), this is the machine artifact.
struct ChapterProvenance: Codable, Equatable {
    var schemaVersion = 1
    var categoryLetter: String
    var passages: [PassageProvenance]

    struct PassageProvenance: Codable, Equatable {
        var id: String
        var text: String
        var links: [SegmentLink]
        /// Displayable verbatim quotes for this passage (union of its links' quotes). Computed,
        /// so pruning a link drops its quotes automatically.
        var pullQuotes: [String] { links.flatMap(\.pullQuotes) }
    }

    struct SegmentLink: Codable, Equatable {
        var questionID: String
        var clipFilename: String?          // source-segment identity (voice); nil for text
        var segmentIndex: Int
        var matchStatus: ProvenanceAnchor.MatchStatus
        var quote: ProvenanceAnchor.QuoteSelector
        var position: ProvenanceAnchor.PositionSelector
        var sourceHash: String             // hash of the source segment (staleness)
        var score: Double
        var pullQuotes: [String]           // verbatim quotes from THIS segment in the passage
    }
}

extension ChapterGenerator {

    /// One contributing source segment for provenance computation.
    struct SourceSegment {
        var questionID: String
        var segmentIndex: Int
        var text: String
        var clipFilename: String?
        var isEdited: Bool
    }

    /// Flatten answers into contributing source segments (answer order preserved).
    static func sourceSegments(from answers: [Answer]) -> [SourceSegment] {
        answers.sorted { $0.questionID < $1.questionID }.flatMap { answer in
            answer.segments.enumerated().map { index, seg in
                SourceSegment(
                    questionID: answer.questionID,
                    segmentIndex: index,
                    text: seg.text,
                    clipFilename: seg.clipFilename,
                    isEdited: seg.isEdited
                )
            }
        }
    }

    /// Compute provenance post-hoc (KTD12): match each draft paragraph against the source
    /// segments, record a link where a segment sentence resolves (exact/fuzzy) in the passage,
    /// and collect verbatim pull-quotes — exact substrings of non-edited segments. No confident
    /// match means no link and no quote, never a wrong one.
    static func computeProvenance(
        draft: String,
        segments: [SourceSegment],
        categoryLetter: Character
    ) -> ChapterProvenance {
        let paragraphs = splitParagraphs(draft)
        var passages: [ChapterProvenance.PassageProvenance] = []

        for (pi, para) in paragraphs.enumerated() {
            var links: [ChapterProvenance.SegmentLink] = []
            for seg in segments where !ProvenanceAnchor.normalize(seg.text).isEmpty {
                var best: ProvenanceAnchor.Match?
                var quotes: [String] = []
                for sentence in sentences(of: seg.text) {
                    guard ProvenanceAnchor.normalize(sentence).split(separator: " ").count >= 4 else { continue }
                    // Verbatim pull-quote: the person's sentence appears exactly in the prose.
                    if !seg.isEdited, ProvenanceAnchor.isExactQuote(sentence, of: para) {
                        quotes.append(ProvenanceAnchor.normalize(sentence))
                    }
                    // Link strength = how well the sentence is reflected in the passage.
                    let inPassage = ProvenanceAnchor.resolve(needle: sentence, in: para)
                    guard inPassage.status != .none else { continue }
                    // Anchor into the SEGMENT (source) for the facing-page view + staleness.
                    let inSegment = ProvenanceAnchor.resolve(needle: sentence, in: seg.text)
                    let anchor = inSegment.status != .none ? inSegment : inPassage
                    if best == nil || inPassage.score > best!.score {
                        best = ProvenanceAnchor.Match(
                            status: inPassage.status, quote: anchor.quote, position: anchor.position, score: inPassage.score
                        )
                    }
                }
                if let best, best.status != .none {
                    links.append(ChapterProvenance.SegmentLink(
                        questionID: seg.questionID,
                        clipFilename: seg.clipFilename,
                        segmentIndex: seg.segmentIndex,
                        matchStatus: best.status,
                        quote: best.quote ?? .init(exact: "", prefix: "", suffix: ""),
                        position: best.position ?? .init(start: 0, end: 0),
                        sourceHash: ProvenanceAnchor.contentHash(seg.text),
                        score: best.score,
                        pullQuotes: dedupPreservingOrder(quotes)
                    ))
                }
            }
            passages.append(.init(id: "p\(pi)", text: para, links: links))
        }
        return ChapterProvenance(schemaVersion: 1, categoryLetter: String(categoryLetter), passages: passages)
    }

    /// Split prose into paragraphs on blank lines, trimmed, empties dropped.
    static func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Naive sentence split on terminal punctuation — enough for pull-quote candidate spans.
    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func dedupPreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
