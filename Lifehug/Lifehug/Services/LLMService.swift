import Foundation
import Hub
import MLXLMCommon
import MLXLLM
import os

@Observable
@MainActor
final class LLMService {
    var isGenerating: Bool = false

    /// Whether the shared LLM container is available. On the simulator MLX never
    /// loads, so a mock flag stands in.
    var isLoaded: Bool {
        #if targetEnvironment(simulator)
        return simulatorModelLoaded
        #else
        return modelContainer != nil
        #endif
    }

    #if targetEnvironment(simulator)
    private var simulatorModelLoaded = false
    #endif

    private let logger = Logger(subsystem: "com.lifehug.app", category: "LLM")

    /// Single-owner container source (U7 / R6). LLMService does NOT load its own
    /// container — it borrows the one loaded and owned by `ModelDownloader` (exposed
    /// via `ModelState`) so only one Llama container is ever resident. Wired by the
    /// app at launch via `configureContainerProvider`.
    private var containerProvider: (@MainActor () -> ModelContainer?)?
    /// Triggers the single downloader-owned load path (used by call sites that call
    /// `loadModel()` as a safety net). Idempotent on the downloader side.
    private var loadTrigger: (@MainActor () async -> Void)?
    private var modelContainer: ModelContainer? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return containerProvider?()
        #endif
    }
    private var chatSession: ChatSession?

    /// System prompt captured by `startNewSession`, retained so the session can be
    /// created lazily once the model container finishes loading (cold-launch fix, R4).
    /// `private(set)` keeps the setter internal-only but exposes the getter to tests.
    private(set) var pendingSystemPrompt: String?

    private let generateParameters = GenerateParameters(
        temperature: 0.7,
        topP: 0.9
    )
    private let maxTokens = 150  // Short: acknowledgment + follow-up question only

    // MARK: - Model Loading

    /// Wire the shared container source. The app calls this once at launch so
    /// LLMService borrows the single `ModelDownloader` container rather than loading
    /// a second one (single-owner invariant, R6). `get` reads the current container;
    /// `load` triggers the downloader's (idempotent) load path.
    func configureContainerProvider(
        get: @escaping @MainActor () -> ModelContainer?,
        load: @escaping @MainActor () async -> Void
    ) {
        containerProvider = get
        loadTrigger = load
    }

    /// Ensure the shared LLM container is loaded. LLMService does not own or build a
    /// container; it delegates to the single downloader load path so call sites keep
    /// working without creating a second container.
    func loadModel() async throws {
        #if targetEnvironment(simulator)
        // MLX requires a real Metal GPU — use mock responses.
        simulatorModelLoaded = true
        logger.info("Simulator detected — LLM model loading skipped, using mock responses")
        #else
        guard modelContainer == nil else { return }
        await loadTrigger?()
        #endif
    }

    func unloadModel() {
        // Release the session (which retains the shared container) so the single
        // owner (ModelDownloader) can actually free the memory. The container itself
        // is not owned here, so it is not (and cannot be) niled here.
        chatSession = nil
        #if targetEnvironment(simulator)
        simulatorModelLoaded = false
        #endif
        logger.info("LLM session released")
    }

    // MARK: - Conversation

    func startNewSession(systemPrompt: String) {
        // Always retain the prompt so a session can materialize later even if the
        // container is not ready yet (cold launch — loadModel() may still be running).
        pendingSystemPrompt = systemPrompt

        guard let container = modelContainer else {
            // Cold launch: defer session creation to first use once the model loads.
            chatSession = nil
            logger.info("Model not loaded — session creation deferred to first use")
            return
        }

        chatSession = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: generateParameters
        )
        logger.info("New chat session started")
    }

    /// Returns the active session, creating it lazily from the pending prompt if the
    /// container has since loaded. Returns nil only when the container is still absent.
    private func ensureSession() -> ChatSession? {
        if let chatSession {
            return chatSession
        }
        guard let container = modelContainer, let prompt = pendingSystemPrompt else {
            return nil
        }
        let session = ChatSession(
            container,
            instructions: prompt,
            generateParameters: generateParameters
        )
        chatSession = session
        logger.info("Chat session materialized lazily after model load")
        return session
    }

    func streamResponse(to userMessage: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if targetEnvironment(simulator)
            // Canned streamed response so the full voice loop (LLM → TTS) is exercisable
            // on the simulator without a Metal GPU (mirrors respond()).
            self.isGenerating = true
            let mockTask = Task {
                let mock = "That's really interesting — tell me more about what that meant to you."
                for word in mock.split(separator: " ") {
                    guard !Task.isCancelled else { break }
                    continuation.yield(String(word) + " ")
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
                await MainActor.run { self.isGenerating = false }
            }
            continuation.onTermination = { _ in mockTask.cancel() }
            #else
            guard let session = self.ensureSession() else {
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
            let task = Task {
                var tokenCount = 0

                do {
                    for try await chunk in unsafeSession.streamResponse(to: userMessage) {
                        // Stop as soon as the consumer cancels (stop/interrupt): this
                        // halts MLX generation instead of burning GPU and mutating the
                        // shared session after the pipeline moved on (U8).
                        guard !Task.isCancelled else { break }
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

            // When the consumer stops iterating (cancel/interrupt/teardown), cancel the
            // producer so generation actually stops. Without this the unstructured task
            // ran to completion regardless of VoicePipeline's activeTask?.cancel().
            continuation.onTermination = { _ in
                task.cancel()
            }
            #endif
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
        guard let session = ensureSession() else {
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
