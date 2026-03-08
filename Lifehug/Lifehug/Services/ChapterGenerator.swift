import Foundation
import os

enum ChapterGenerator {
    enum Pass: String, Sendable {
        case extracting = "Reading your answers..."
        case outlining = "Organizing the story..."
        case writing = "Writing the chapter..."
    }

    private static let logger = Logger(subsystem: "com.lifehug.app", category: "ChapterGenerator")

    /// Generate a chapter using a 3-pass pipeline optimized for the 1B model.
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

        // Pass 3: Flesh out
        onPassChange?(.writing)
        let draft = try await writeDraft(
            categoryName: category.name,
            userName: userName,
            outline: outline,
            bullets: bullets,
            llmService: llmService
        )
        logger.info("Writing pass complete: \(draft.count) characters")

        return draft
    }

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

        // Batch into groups of 10 to stay within the 1B model's context window
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
        llmService: LLMService
    ) async throws -> String {
        let prompt = """
        Write a memoir chapter called "\(categoryName)" for \(userName).
        Follow this outline: \(outline)
        Use these source details: \(bullets)
        Write in first person. Use \(userName)'s own words where possible.
        Keep it authentic — don't add facts they didn't mention.
        """

        return try await llmService.generateLongResponse(to: prompt, maxTokens: 800)
    }
}
