import Testing
import Foundation
@testable import Lifehug

@Suite("LLMService")
@MainActor
struct LLMServiceTests {

    // NOTE: cleanChunk and cleanResponse are `nonisolated static` (internal, not
    // private) so their token-stripping rules are directly testable here — a token
    // leak is invisible on the simulator (MLX inference is mocked), so these tests
    // are the only pre-device proof.

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

    @Test("streamResponse yields a canned response on the simulator (U12)")
    func streamResponseSimulatorMock() async {
        // On the simulator streamResponse serves a canned streamed response so the full
        // voice loop is exercisable without a Metal GPU (U12). The device path's
        // noActiveSession-when-container-nil behavior is verified on device.
        let service = LLMService()
        service.startNewSession(systemPrompt: "x")
        var chunks: [String] = []
        do {
            for try await chunk in service.streamResponse(to: "hello") {
                chunks.append(chunk)
            }
        } catch {
            Issue.record("simulator stream should not throw: \(error)")
        }
        #expect(!chunks.isEmpty)
        #expect(chunks.joined().contains("interesting"))
    }

    @Test("a second startNewSession replaces the retained prompt")
    func startNewSessionReplacesPendingPrompt() {
        let service = LLMService()
        service.startNewSession(systemPrompt: "first")
        service.startNewSession(systemPrompt: "second")
        #expect(service.pendingSystemPrompt == "second")
    }

    // MARK: - cleanResponse (U2)

    @Test("cleanResponse strips a trailing <end_of_turn> so the saved answer is clean")
    func cleanResponseStripsEndOfTurn() {
        let cleaned = LLMService.cleanResponse("What did the kitchen smell like?<end_of_turn>")
        #expect(cleaned == "What did the kitchen smell like?")
    }

    @Test("cleanResponse removes a <think> block including its inner content")
    func cleanResponseRemovesThinkBlock() {
        let cleaned = LLMService.cleanResponse("<think>reasoning</think>answer")
        #expect(cleaned == "answer")
    }

    @Test("cleanResponse drops a dangling unclosed <think> tail")
    func cleanResponseDropsDanglingThinkTail() {
        let cleaned = LLMService.cleanResponse("answer <think>reasoning that never closed")
        #expect(cleaned == "answer")
    }

    @Test("cleanResponse still strips the Llama end tokens")
    func cleanResponseStripsLlamaTokens() {
        let cleaned = LLMService.cleanResponse("Tell me more about that.<|eot_id|><|end_of_text|>")
        #expect(cleaned == "Tell me more about that.")
    }

    @Test("cleanResponse strips ChatML turn tokens")
    func cleanResponseStripsChatMLTokens() {
        let cleaned = LLMService.cleanResponse("<|im_start|>What happened next?<|im_end|>")
        #expect(cleaned == "What happened next?")
    }

    @Test("cleanResponse leaves prose containing a bare < untouched")
    func cleanResponseLeavesBareLessThanAlone() {
        let prose = "Back then 2 < 3 was the only math I trusted, and x < y stayed true."
        #expect(LLMService.cleanResponse(prose) == prose)
    }

    // MARK: - cleanChunk (U2)

    @Test("cleanChunk strips template tag tokens so nothing token-shaped is emitted", arguments: [
        "<end_of_turn>", "<start_of_turn>model", "<start_of_turn>user",
        "<start_of_turn>", "<think>", "</think>",
    ])
    func cleanChunkStripsTagTokens(token: String) {
        // streamResponse yields only non-empty cleaned chunks, so an empty result
        // here means a token-only chunk emits nothing downstream (no TTS leak).
        #expect(LLMService.cleanChunk(token).isEmpty)
    }

    @Test("cleanChunk strips a tag token embedded in a text chunk")
    func cleanChunkStripsEmbeddedTagToken() {
        #expect(LLMService.cleanChunk("here.<start_of_turn>model") == "here.")
    }

    @Test("cleanChunk leaves prose containing a bare < untouched")
    func cleanChunkLeavesBareLessThanAlone() {
        #expect(LLMService.cleanChunk("2 < 3 ") == "2 < 3 ")
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

/// Tier is injected directly so this suite never touches the shared
/// "llm_selected_model" UserDefaults key (suites run concurrently, and
/// ModelConfigTests owns that key).
@Suite("LLMService instruction building")
struct LLMServiceInstructionTests {

    @Test("Balanced tier appends /no_think to session instructions")
    func balancedAppendsNoThink() {
        let instructions = LLMService.sessionInstructions("You are a warm memoir interviewer.", tier: .balanced)
        #expect(instructions.hasPrefix("You are a warm memoir interviewer."))
        #expect(instructions.hasSuffix("/no_think"))
    }

    @Test("Fast and Quality tiers pass instructions through unchanged", arguments: [
        ModelConfig.LLM.ModelOption.fast,
        ModelConfig.LLM.ModelOption.quality,
    ])
    func otherTiersPassThrough(option: ModelConfig.LLM.ModelOption) {
        let base = "You are a warm memoir interviewer."
        let instructions = LLMService.sessionInstructions(base, tier: option)
        #expect(instructions == base)
        #expect(!instructions.contains("/no_think"))
    }

    @Test("Long-form (chapter) instructions carry /no_think on Balanced")
    func longFormInstructionsCarryNoThinkOnBalanced() {
        let instructions = LLMService.sessionInstructions(LLMService.longFormInstructions, tier: .balanced)
        #expect(instructions.contains("memoir writer"))
        #expect(instructions.hasSuffix("/no_think"))
    }
}
