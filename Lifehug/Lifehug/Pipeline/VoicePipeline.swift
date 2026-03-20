import AVFoundation
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
    private(set) var terminationDetected: Bool = false

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Pipeline")
    private let sttService: STTService
    private let llmService: LLMService
    private let ttsService: TTSService

    private var activeTask: Task<Void, Never>?
    private var sentenceBuffer = SentenceBuffer()

    // MARK: - Audio Interruption Handling
    /// Tracks whether a system audio interruption (phone call, Siri, etc.) paused the session.
    private var wasInterrupted: Bool = false
    private var interruptionObserver: (any NSObjectProtocol)?
    private var routeChangeObserver: (any NSObjectProtocol)?

    /// When true, the pipeline will auto-reopen the mic after TTS finishes or interruption ends.
    var autoReopenMic: Bool = false

    var onTranscriptFinalized: ((String) -> Void)?
    var onResponseGenerated: ((String) -> Void)?
    var onTerminationDetected: (@MainActor () -> Void)?

    // MARK: - Termination Phrase Detection

    private static let terminationPhrases: [String] = [
        "that's my answer", "thats my answer",
        "that's all", "thats all",
        "end session",
        "i'm done", "im done"
    ]

    private var terminationStabilityCount: Int = 0
    private var lastDetectedPhrase: String?

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
        removeAudioObservers()
        // Deactivate audio session now that the voice conversation is truly over.
        // This lets other apps (music, podcasts) resume their audio.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Start observing audio interruptions and route changes.
    /// Call when entering a voice conversation loop.
    func wireAudioObservers() {
        observeInterruptions()
        observeRouteChanges()
    }

    /// Wire auto-reopen: after TTS finishes speaking, automatically reopen the mic.
    func wireAutoReopen() {
        autoReopenMic = true
        observeInterruptions()
        observeRouteChanges()
    }

    /// Unwire auto-reopen and remove audio observers.
    func unwireAutoReopen() {
        autoReopenMic = false
        removeAudioObservers()
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
        if newState == .listening {
            activeTask = Task { await runListening() }
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
        terminationStabilityCount = 0
        lastDetectedPhrase = nil

        let stream = sttService.startListening()
        var terminatedByPhrase = false

        for await transcript in stream {
            guard !Task.isCancelled else { return }
            // Cap transcript length to prevent unbounded memory growth
            if transcript.count > 50_000 {
                logger.warning("Transcript exceeded 50K characters — stopping recording")
                sttService.stopListening()
                partialTranscript = String(transcript.prefix(50_000))
                break
            }
            partialTranscript = transcript

            // Check for termination phrase at end of transcript
            let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let matched = Self.terminationPhrases.first(where: { lowered.hasSuffix($0) }) {
                if matched == lastDetectedPhrase {
                    terminationStabilityCount += 1
                } else {
                    lastDetectedPhrase = matched
                    terminationStabilityCount = 1
                }
                if terminationStabilityCount >= 2 {
                    terminatedByPhrase = true
                    sttService.stopListening()
                    break
                }
            } else {
                terminationStabilityCount = 0
                lastDetectedPhrase = nil
            }
        }

        guard !Task.isCancelled else { return }

        let finalTranscript: String
        if terminatedByPhrase {
            finalTranscript = stripTerminationPhrase(from: partialTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            finalTranscript = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if finalTranscript.isEmpty {
            if terminatedByPhrase {
                terminationDetected = true
                onTerminationDetected?()
                state = .idle
            } else {
                error = "I didn't catch that. Try again?"
                state = .idle
            }
            return
        }

        if terminatedByPhrase {
            terminationDetected = true
            onTerminationDetected?()
            state = .idle
            return
        }

        onTranscriptFinalized?(finalTranscript)
        processUserInput(finalTranscript)
    }

    /// Removes any trailing termination phrase from the transcript.
    func stripTerminationPhrase(from text: String) -> String {
        let lowered = text.lowercased()
        for phrase in Self.terminationPhrases {
            if lowered.hasSuffix(phrase) {
                let endIndex = text.index(text.endIndex, offsetBy: -phrase.count)
                return String(text[text.startIndex..<endIndex])
            }
        }
        return text
    }

    // MARK: - Processing (LLM -> TTS)

    /// Write a breadcrumb to disk so we can see the last pipeline stage after a crash.
    /// File persists across app launches — check it on startup to detect crash-during-speech.
    private func writeBreadcrumb(_ stage: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pipeline-breadcrumb.txt")
        let content = "\(stage) | memory: \(MemoryMonitor.availableMB)MB | \(Date())"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func processUserInput(_ text: String) {
        state = .processing
        responseChunks = ""
        sentenceBuffer = SentenceBuffer()
        checkMemoryPressure()
        writeBreadcrumb("processUserInput-start")

        activeTask?.cancel()
        activeTask = Task {
            do {
                // IMPORTANT: LLM (MLX) and Kokoro TTS (MLX) both use Metal GPU.
                // Running them concurrently on separate threads crashes the GPU driver.
                // Solution: collect ALL LLM output first, THEN synthesize/speak sentences.
                // This serializes Metal GPU access at the cost of slightly delayed first speech.
                var fullResponse = ""
                var sentences: [String] = []

                // Phase 1: Generate complete LLM response (Metal GPU for LLM only)
                let stream = llmService.streamResponse(to: text)
                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    fullResponse += chunk
                    responseChunks = fullResponse
                    sentenceBuffer.append(chunk)

                    while let sentence = sentenceBuffer.extractSentence() {
                        sentences.append(sentence)
                    }
                }

                // Flush remaining buffer
                let remaining = sentenceBuffer.flush()
                if !remaining.isEmpty {
                    sentences.append(remaining)
                }

                guard !Task.isCancelled else { return }

                self.logger.info("LLM complete: \(sentences.count) sentences, memory: \(MemoryMonitor.availableMB)MB")
                self.writeBreadcrumb("llm-complete-\(sentences.count)-sentences")

                // Phase 2: Speak sentences sequentially (Metal GPU for Kokoro only)
                // LLM inference is complete — no concurrent Metal access.
                for (index, sentence) in sentences.enumerated() {
                    guard !Task.isCancelled else { break }
                    state = .speaking
                    self.logger.info("Speaking sentence \(index + 1)/\(sentences.count) (\(sentence.count) chars), memory: \(MemoryMonitor.availableMB)MB")
                    self.writeBreadcrumb("speaking-\(index + 1)-of-\(sentences.count)")
                    await ttsService.speak(sentence)
                    self.logger.info("Sentence \(index + 1) complete, memory: \(MemoryMonitor.availableMB)MB")
                    guard !Task.isCancelled else { break }
                }

                onResponseGenerated?(fullResponse)

                // Auto-reopen mic for conversation loop
                if self.autoReopenMic {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, self.autoReopenMic else { return }
                    self.startListening()
                }

            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Pipeline processing error: \(error)")
                self.error = "Something went wrong. Let me try again."
                self.state = .idle
            }
        }
    }

    // MARK: - Audio Interruption & Route Change Handling

    private func observeInterruptions() {
        // Remove any existing observer to avoid duplicates
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { @Sendable [weak self] notification in
            // Extract Sendable values before crossing isolation boundary
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            logger.info("Audio interruption began (phone call, Siri, etc.)")
            if state == .listening || state == .speaking {
                wasInterrupted = true
                sttService.stopListening()
                ttsService.stop()
                activeTask?.cancel()
                activeTask = nil
                state = .idle
            }

        case .ended:
            guard let optionsValue else {
                wasInterrupted = false
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) && wasInterrupted {
                logger.info("Audio interruption ended — resuming session")
                wasInterrupted = false
                // Re-activate audio session after interruption
                try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                // Resume listening if we were in a voice conversation loop
                if autoReopenMic {
                    startListening()
                }
            } else {
                wasInterrupted = false
            }

        @unknown default:
            break
        }
    }

    private func observeRouteChanges() {
        // Remove any existing observer to avoid duplicates
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] notification in
            // Extract Sendable value before crossing isolation boundary
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let reasonValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

                if reason == .oldDeviceUnavailable {
                    // Audio device disconnected (e.g., AirPods removed mid-session)
                    if self.state == .listening {
                        self.logger.info("Audio route changed — device unavailable, pausing")
                        self.sttService.stopListening()
                        self.activeTask?.cancel()
                        self.activeTask = nil
                        self.state = .idle
                    }
                }
            }
        }
    }

    private func removeAudioObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        wasInterrupted = false
    }

    // MARK: - Memory Monitoring

    func checkMemoryPressure() {
        let pressure = MemoryMonitor.currentPressure
        switch pressure {
        case .normal:
            break
        case .elevated:
            // Degrade to system TTS but keep LLM loaded
            logger.warning("Elevated memory pressure (\(MemoryMonitor.availableMB)MB) — degrading to system TTS")
            ttsService.degradeToSystemTTS()
        case .critical, .emergency:
            // Unload Kokoro model entirely and fall back to system TTS
            logger.error("Critical/emergency memory pressure (\(MemoryMonitor.availableMB)MB) — unloading Kokoro")
            ttsService.degradeToSystemTTS()
            ttsService.unloadKokoroModel()
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
