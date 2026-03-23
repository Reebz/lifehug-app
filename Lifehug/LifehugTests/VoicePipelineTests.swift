import Testing
@testable import Lifehug

@Suite("VoicePipeline")
@MainActor
struct VoicePipelineTests {

    // MARK: - Helpers

    /// Creates a VoicePipeline with lightweight service stubs.
    /// The services are constructed but never load models or access hardware.
    private func makePipeline() -> VoicePipeline {
        VoicePipeline(
            sttService: STTService(),
            llmService: LLMService(),
            ttsService: TTSService()
        )
    }

    // MARK: - stripTerminationPhrase

    @Test("Strips 'that's my answer' from end of text")
    func stripThatsMyAnswer() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "I grew up in Texas that's my answer")
        #expect(result == "I grew up in Texas ")
    }

    @Test("Strips 'that's all' from end of text")
    func stripThatsAll() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "That is everything that's all")
        #expect(result == "That is everything ")
    }

    @Test("Strips 'i'm done' from end of text")
    func stripImDone() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "Nothing more to say i'm done")
        #expect(result == "Nothing more to say ")
    }

    @Test("Strips 'end session' from end of text")
    func stripEndSession() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "That covers it end session")
        #expect(result == "That covers it ")
    }

    @Test("No matching phrase returns text unchanged")
    func noMatchReturnsUnchanged() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "I love telling stories")
        #expect(result == "I love telling stories")
    }

    @Test("Matching is case insensitive")
    func caseInsensitive() {
        let pipeline = makePipeline()
        let result = pipeline.stripTerminationPhrase(from: "My story That's My Answer")
        #expect(result == "My story ")
    }

    // MARK: - PipelineState Equatable

    @Test("PipelineState cases are equatable")
    func pipelineStateEquatable() {
        #expect(PipelineState.idle == PipelineState.idle)
        #expect(PipelineState.listening == PipelineState.listening)
        #expect(PipelineState.processing == PipelineState.processing)
        #expect(PipelineState.speaking == PipelineState.speaking)
        #expect(PipelineState.idle != PipelineState.listening)
        #expect(PipelineState.processing != PipelineState.speaking)
    }
}
