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

    private static let modelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"

    private let generateParameters = GenerateParameters(
        temperature: 0.7,
        topP: 0.9
    )
    private let maxTokens = 200

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
            Task { @MainActor in
                guard let session = self.chatSession else {
                    continuation.finish(throwing: LLMError.noActiveSession)
                    return
                }

                self.isGenerating = true
                var tokenCount = 0

                do {
                    for try await chunk in session.streamResponse(to: userMessage) {
                        // Filter out system prompt leakage and special tokens
                        let cleaned = self.cleanChunk(chunk)
                        if !cleaned.isEmpty {
                            continuation.yield(cleaned)
                        }
                        tokenCount += 1
                        if tokenCount >= self.maxTokens {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    self.logger.error("LLM generation error: \(error)")
                    continuation.finish(throwing: error)
                }

                self.isGenerating = false
                self.logger.info("Generated \(tokenCount) tokens")
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

        nonisolated(unsafe) let unsafeSession = session
        let result = try await unsafeSession.respond(to: userMessage)
        return cleanResponse(result)
        #endif
    }

    // MARK: - Text Cleaning

    private func cleanChunk(_ chunk: String) -> String {
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
        You are a warm, curious memoir interviewer helping \(userName) capture their life story. \
        You're having a spoken conversation — keep responses natural, conversational, and concise (2-3 sentences).

        The current question is: "\(questionText)"

        Guidelines:
        - Be genuinely curious. Ask follow-ups that show you were listening.
        - Use sensory questions: "What did that look like? Sound like?"
        - Use emotional anchors: "How did that make you feel?"
        - Ask for specific moments: "Can you think of one time when..."
        - Never be sycophantic. Be warm but real.
        - Keep responses SHORT — this is a voice conversation, not an essay.
        - Don't summarize what they said back to them. Move the story forward.
        - If they give a short answer, gently probe deeper.
        - After 2-3 exchanges, offer to wrap up: "Is there anything else about this you want to capture?"
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
