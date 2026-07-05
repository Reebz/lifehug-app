import Testing
import Foundation
@testable import Lifehug

@Suite("LLMService")
@MainActor
struct LLMServiceTests {

    // NOTE: cleanChunk is `private static` on LLMService, so it cannot be called
    // directly even with @testable import. We test it indirectly by verifying that
    // memoirInterviewerPrompt (which IS accessible) produces correct output, and
    // by documenting the cleanChunk behavior via streamResponse integration tests
    // that would require a loaded model (out of scope for unit tests).

    // MARK: - memoirInterviewerPrompt

    @Test("memoirInterviewerPrompt contains the user's name")
    func promptContainsUserName() {
        let prompt = LLMService.memoirInterviewerPrompt(
            userName: "Margaret",
            questionText: "Tell me about your childhood."
        )
        #expect(prompt.contains("Margaret"))
    }

    @Test("memoirInterviewerPrompt contains the question text")
    func promptContainsQuestionText() {
        let question = "What's your earliest memory?"
        let prompt = LLMService.memoirInterviewerPrompt(
            userName: "Test",
            questionText: question
        )
        #expect(prompt.contains(question))
    }

    @Test("memoirInterviewerPrompt includes TTS length constraint")
    func promptIncludesTTSConstraint() {
        let prompt = LLMService.memoirInterviewerPrompt(
            userName: "Alice",
            questionText: "Any question"
        )
        // The prompt should mention text-to-speech and short response requirements
        #expect(prompt.contains("text-to-speech"))
        #expect(prompt.contains("200 characters"))
    }

    @Test("memoirInterviewerPrompt handles special characters in name and question")
    func promptSpecialCharacters() {
        let prompt = LLMService.memoirInterviewerPrompt(
            userName: "O'Brien-Smith",
            questionText: "What's the \"big picture\" for you & your family?"
        )
        #expect(prompt.contains("O'Brien-Smith"))
        #expect(prompt.contains("\"big picture\""))
    }

    // MARK: - Lazy session lifecycle (U1 / R4)

    @Test("startNewSession retains the pending prompt when the container is nil")
    func startNewSessionRetainsPendingPrompt() {
        // On the simulator MLX never loads, so modelContainer is always nil — this is
        // the cold-launch shape: the prompt must be retained for later materialization.
        let service = LLMService()
        service.startNewSession(systemPrompt: "SYSTEM_PROMPT_MARKER")
        #expect(service.pendingSystemPrompt == "SYSTEM_PROMPT_MARKER")
    }

    @Test("streamResponse surfaces noActiveSession when the container is still nil")
    func streamResponseThrowsWithoutContainer() async {
        let service = LLMService()
        service.startNewSession(systemPrompt: "x")
        var caught: Error?
        do {
            for try await _ in service.streamResponse(to: "hello") {
                // no chunks expected — the stream should finish with an error
            }
        } catch {
            caught = error
        }
        #expect((caught as? LLMError) == .noActiveSession)
    }

    @Test("a second startNewSession replaces the retained prompt")
    func startNewSessionReplacesPendingPrompt() {
        let service = LLMService()
        service.startNewSession(systemPrompt: "first")
        service.startNewSession(systemPrompt: "second")
        #expect(service.pendingSystemPrompt == "second")
    }

    // MARK: - Single-owner container lifecycle (U7 / R6)

    @Test("loadModel marks loaded on simulator; unloadModel releases it")
    func simulatorLoadUnload() async {
        // On the simulator MLX never loads a real container, so isLoaded reflects the
        // mock flag. The single-owner (no second container) property is device-verified.
        let service = LLMService()
        #expect(service.isLoaded == false)
        try? await service.loadModel()
        #expect(service.isLoaded == true)
        service.unloadModel()
        #expect(service.isLoaded == false)
    }
}
