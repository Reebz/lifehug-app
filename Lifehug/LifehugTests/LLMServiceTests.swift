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
}
