import Foundation
import os

enum PipelineState: Equatable {
    case idle
    case listening
    case processing
    case speaking
}

@Observable
@MainActor
final class VoicePipeline {
    var state: PipelineState = .idle
    var partialTranscript: String = ""
    var responseChunks: String = ""
    var error: String?

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Pipeline")
    private let sttService: STTService
    private let llmService: LLMService
    private let ttsService: TTSService

    private var activeTask: Task<Void, Never>?
    private var sentenceBuffer = SentenceBuffer()

    var onTranscriptFinalized: ((String) -> Void)?
    var onResponseGenerated: ((String) -> Void)?

    init(sttService: STTService, llmService: LLMService, ttsService: TTSService) {
        self.sttService = sttService
        self.llmService = llmService
        self.ttsService = ttsService
    }

    // MARK: - Public API

    func startListening() {
        transition(to: .listening)
    }

    func interrupt() {
        ttsService.stop()
        transition(to: .listening)
    }

    func stopAll() {
        ttsService.stop()
        sttService.stopListening()
        activeTask?.cancel()
        activeTask = nil
        state = .idle
    }

    /// Process a text input directly (bypass STT)
    func processTextInput(_ text: String) {
        partialTranscript = text
        onTranscriptFinalized?(text)
        transition(to: .processing)
        processUserInput(text)
    }

    // MARK: - State Machine

    private func transition(to newState: PipelineState) {
        logger.info("Pipeline: \(String(describing: self.state)) -> \(String(describing: newState))")
        activeTask?.cancel()
        state = newState
        activeTask = Task { await runState(newState) }
    }

    private func runState(_ state: PipelineState) async {
        switch state {
        case .idle:
            break

        case .listening:
            await runListening()

        case .processing:
            break // Processing is kicked off by runListening or processTextInput

        case .speaking:
            break // Speaking is handled by TTS callbacks
        }
    }

    // MARK: - Listening

    private func runListening() async {
        if !sttService.isAuthorized {
            await sttService.requestAuthorization()
        }
        guard sttService.isAuthorized else {
            error = "Speech recognition not authorized"
            state = .idle
            return
        }

        partialTranscript = ""
        responseChunks = ""

        let stream = sttService.startListening()

        for await transcript in stream {
            guard !Task.isCancelled else { return }
            partialTranscript = transcript
        }

        guard !Task.isCancelled else { return }

        let finalTranscript = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if finalTranscript.isEmpty {
            error = "I didn't catch that. Try again?"
            state = .idle
            return
        }

        onTranscriptFinalized?(finalTranscript)
        processUserInput(finalTranscript)
    }

    // MARK: - Processing (LLM -> TTS)

    private func processUserInput(_ text: String) {
        state = .processing
        responseChunks = ""
        sentenceBuffer = SentenceBuffer()

        activeTask?.cancel()
        activeTask = Task {
            do {
                let stream = llmService.streamResponse(to: text)
                var fullResponse = ""

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }

                    fullResponse += chunk
                    responseChunks = fullResponse
                    sentenceBuffer.append(chunk)

                    // Check for complete sentences to send to TTS
                    while let sentence = sentenceBuffer.extractSentence() {
                        state = .speaking
                        await ttsService.speak(sentence)
                    }
                }

                // Flush remaining buffer
                let remaining = sentenceBuffer.flush()
                if !remaining.isEmpty {
                    state = .speaking
                    await ttsService.speak(remaining)
                }

                onResponseGenerated?(fullResponse)

            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Pipeline processing error: \(error)")
                self.error = "Something went wrong. Let me try again."
                self.state = .idle
            }
        }
    }

    // MARK: - Memory Monitoring

    func checkMemoryPressure() {
        let available = os_proc_available_memory()
        if available < 300_000_000 { // 300MB
            logger.warning("Memory low (\(available / 1_000_000)MB available), switching to system TTS")
            ttsService.degradeToSystemTTS()
        }
    }
}

// MARK: - Sentence Buffer

struct SentenceBuffer {
    private var buffer = ""
    private static let abbreviations: Set<String> = ["Dr.", "Mr.", "Mrs.", "Ms.", "Jr.", "Sr.", "U.S.", "etc."]

    mutating func append(_ text: String) {
        buffer += text
    }

    mutating func extractSentence() -> String? {
        // Look for sentence-ending punctuation followed by space or end
        let chars = Array(buffer)
        for i in 0..<chars.count {
            let ch = chars[i]
            guard ch == "." || ch == "!" || ch == "?" else { continue }

            // Check if next char is space, newline, or end of buffer
            let isEnd = i == chars.count - 1
            let isFollowedBySpace = !isEnd && (chars[i + 1] == " " || chars[i + 1] == "\n")

            guard isEnd || isFollowedBySpace else { continue }

            // Skip abbreviations
            let prefix = String(chars[0...i])
            if Self.abbreviations.contains(where: { prefix.hasSuffix($0) }) {
                continue
            }

            // Skip decimal numbers (digit before period)
            if ch == "." && i > 0 && chars[i - 1].isNumber {
                continue
            }

            // Skip ellipsis
            if ch == "." && i >= 2 && chars[i - 1] == "." && chars[i - 2] == "." {
                continue
            }

            // Found sentence boundary
            let sentenceEnd = buffer.index(buffer.startIndex, offsetBy: i + 1)
            let sentence = String(buffer[buffer.startIndex..<sentenceEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[sentenceEnd...])
                .trimmingCharacters(in: .init(charactersIn: " "))
            return sentence.isEmpty ? nil : sentence
        }

        return nil
    }

    mutating func flush() -> String {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remaining
    }
}
