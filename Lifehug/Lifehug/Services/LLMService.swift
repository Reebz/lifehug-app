import Foundation
import Hub
import MLXLMCommon
import MLXLLM
import os

@Observable
@MainActor
final class LLMService {
    var isLoaded: Bool = false
    var isGenerating: Bool = false

    private let logger = Logger(subsystem: "com.lifehug.app", category: "LLM")
    private var modelContainer: ModelContainer?
    private var chatSession: ChatSession?

    /// Dynamic — reads the currently selected model. Must NOT be `let` (would go stale after model switch).
    private static var modelID: String { ModelConfig.LLM.modelID }

    private let generateParameters = GenerateParameters(
        temperature: 0.7,
        topP: 0.9
    )
    private let maxTokens = 150  // Short: acknowledgment + follow-up question only

    // MARK: - Model Loading

    func loadModel() async throws {
        #if targetEnvironment(simulator)
        // MLX requires a real Metal GPU — skip loading on simulator.
        isLoaded = true
        logger.info("Simulator detected — LLM model loading skipped, using mock responses")
        return
        #else
        guard modelContainer == nil else {
            isLoaded = true
            return
        }

        logger.info("Loading LLM model...")

        let configuration = ModelConfiguration(id: Self.modelID)
        let storage = StorageService()
        let hubAPI = HubApi(downloadBase: storage.modelsDirectory)

        let container = try await LLMModelFactory.shared.loadContainer(
            hub: hubAPI,
            configuration: configuration
        ) { progress in
            Task { @MainActor in
                self.logger.debug("Model load progress: \(progress)")
            }
        }

        self.modelContainer = container
        isLoaded = true
        logger.info("LLM model loaded successfully")
        #endif
    }

    func unloadModel() {
        modelContainer = nil
        chatSession = nil
        isLoaded = false
        logger.info("LLM model unloaded")
    }

    // MARK: - Conversation

    func startNewSession(systemPrompt: String) {
        guard let container = modelContainer else {
            logger.error("Cannot start session — model not loaded")
            return
        }

        chatSession = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: generateParameters
        )
        logger.info("New chat session started")
    }

    func streamResponse(to userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let session = self.chatSession else {
                continuation.finish(throwing: LLMError.noActiveSession)
                return
            }

            self.isGenerating = true
            let maxTokens = self.maxTokens

            // SAFETY: ChatSession is not Sendable but we consume it sequentially.
            // No concurrent access — we await completion before any mutation.
            nonisolated(unsafe) let unsafeSession = session

            // The AsyncThrowingStream build closure is @Sendable, so this Task
            // does NOT inherit MainActor — token generation runs off-MainActor,
            // allowing TTS playback to overlap.
            Task {
                var tokenCount = 0

                do {
                    for try await chunk in unsafeSession.streamResponse(to: userMessage) {
                        let cleaned = Self.cleanChunk(chunk)
                        if !cleaned.isEmpty {
                            continuation.yield(cleaned)
                        }
                        tokenCount += 1
                        if tokenCount >= maxTokens {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                await MainActor.run {
                    self.isGenerating = false
                    self.logger.info("Generated \(tokenCount) tokens")
                }
            }
        }
    }

    func respond(to userMessage: String) async throws -> String {
        #if targetEnvironment(simulator)
        isGenerating = true
        // Simulate a brief delay for realism
        try? await Task.sleep(for: .milliseconds(500))
        isGenerating = false
        return "That's really interesting — tell me more about what that meant to you."
        #else
        guard let session = chatSession else {
            throw LLMError.noActiveSession
        }

        isGenerating = true
        defer { isGenerating = false }

        // SAFETY: ChatSession is not Sendable but the await call may cross isolation
        // boundaries internally. No concurrent access — we await the result synchronously.
        nonisolated(unsafe) let unsafeSession = session
        let result = try await unsafeSession.respond(to: userMessage)
        return cleanResponse(result)
        #endif
    }

    // MARK: - Long-Form Generation

    /// Generate a longer response with a configurable token limit.
    /// Used for chapter generation where the default maxTokens is too short.
    /// This creates a temporary session (does not disturb any active conversation).
    func generateLongResponse(to prompt: String, maxTokens: Int = 500) async throws -> String {
        #if targetEnvironment(simulator)
        isGenerating = true
        try? await Task.sleep(for: .milliseconds(300))
        isGenerating = false
        return "Sample long-form response for: \(prompt.prefix(50))..."
        #else
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Use a dedicated session so we don't pollute the conversation session
        let session = ChatSession(
            container,
            instructions: "You are a skilled memoir writer. Follow the instructions precisely.",
            generateParameters: generateParameters
        )

        // SAFETY: ChatSession is not Sendable but the stream is consumed sequentially.
        // No concurrent access — this local session is only used within this method.
        nonisolated(unsafe) let unsafeSession = session

        // Stream and collect tokens up to the specified limit
        var result = ""
        var tokenCount = 0
        for try await chunk in unsafeSession.streamResponse(to: prompt) {
            let cleaned = Self.cleanChunk(chunk)
            if !cleaned.isEmpty {
                result += cleaned
            }
            tokenCount += 1
            if tokenCount >= maxTokens {
                break
            }
        }

        logger.info("Long-form generation complete: \(tokenCount) tokens")
        return cleanResponse(result)
        #endif
    }

    // MARK: - Text Cleaning

    private nonisolated static func cleanChunk(_ chunk: String) -> String {
        var text = chunk
        // Strip special tokens
        text = text.replacingOccurrences(of: "<|", with: "")
        text = text.replacingOccurrences(of: "|>", with: "")
        // Strip common markdown artifacts from LLM output
        if text.hasPrefix("```") || text.hasSuffix("```") {
            text = text.replacingOccurrences(of: "```", with: "")
        }
        return text
    }

    private func cleanResponse(_ response: String) -> String {
        var text = response
        text = text.replacingOccurrences(of: "<|eot_id|>", with: "")
        text = text.replacingOccurrences(of: "<|end_of_text|>", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - System Prompt

    static func memoirInterviewerPrompt(userName: String, questionText: String) -> String {
        """
        You are a warm memoir interviewer having a spoken conversation with \(userName). \
        The current question: "\(questionText)"

        CRITICAL: Your responses will be read aloud by text-to-speech. Keep them EXTREMELY short — \
        under 200 characters total. Format: one brief acknowledgment + one follow-up question. Examples:
        - "That sounds like a turning point. What were you feeling in that moment?"
        - "Your dad clearly mattered. Can you picture a specific time he surprised you?"
        - "Interesting. What did that place look like?"

        Rules:
        - Maximum TWO short sentences. Never more.
        - First sentence: brief acknowledgment (NOT a summary of what they said).
        - Second sentence: one specific follow-up question.
        - Be genuinely curious. Be warm but not sycophantic.
        - Favor sensory and emotional questions over abstract ones.
        - If they seem done, say "Thank you for sharing that." and nothing else.
        """
    }
}

enum LLMError: Error, LocalizedError {
    case noActiveSession
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active conversation session"
        case .modelNotLoaded:
            return "LLM model is not loaded"
        }
    }
}
