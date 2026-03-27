import Foundation
import AVFoundation
import WhisperKit
import os

/// On-device speech-to-text using WhisperKit's AudioStreamTranscriber.
/// Creates a new AudioStreamTranscriber per recording session (actor handles
/// recording, VAD, real-time transcription, and segment confirmation internally).
/// Audio session is configured once by VoicePipeline at conversation start.
@Observable
@MainActor
final class STTService {
    var isAuthorized: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""
    var error: String?
    var isASRReady: Bool { whisperPipe != nil }

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    /// WhisperKit pipeline — created once at launch, persists across sessions.
    private var whisperPipe: WhisperKit?

    private var continuation: AsyncStream<String>.Continuation?
    private var transcriber: AudioStreamTranscriber?
    private var transcriptionTask: Task<Void, Never>?

    /// Maximum recording duration in samples (3 minutes at 16kHz).
    private let maxRecordingSamples = 16000 * 180

    // MARK: - Model Loading

    func loadASRModel() async {
        guard whisperPipe == nil else { return }
        do {
            logger.info("Loading WhisperKit small.en model...")
            let pipe = try await WhisperKit(WhisperKitConfig(
                model: "small.en",
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            ))
            self.whisperPipe = pipe
            logger.info("WhisperKit loaded successfully")
        } catch {
            logger.error("WhisperKit load failed: \(error)")
            self.error = "Voice recognition failed to load. Please restart."
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        #if targetEnvironment(simulator)
        isAuthorized = true
        return
        #else
        let micGranted: Bool
        if #available(iOS 17, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await Self.requestMicPermission()
        }
        isAuthorized = micGranted
        if !micGranted {
            error = "Microphone access not authorized. Please enable in Settings."
        }
        #endif
    }

    private nonisolated static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Start Listening

    func startListening() -> AsyncStream<String> {
        #if targetEnvironment(simulator)
        return AsyncStream<String> { continuation in
            Task { @MainActor in
                self.isRecording = true
                try? await Task.sleep(for: .seconds(1.5))
                let mockText = "This is a simulated voice answer for testing on the simulator."
                self.partialTranscript = mockText
                continuation.yield(mockText)
                continuation.finish()
                self.isRecording = false
            }
        }
        #else
        self.error = nil
        self.partialTranscript = ""

        // Ensure WhisperKit is loaded
        guard let pipe = whisperPipe, let tokenizer = pipe.tokenizer else {
            logger.error("startListening called but WhisperKit not loaded")
            self.error = "Voice recognition not available. Please restart."
            return AsyncStream<String> { $0.finish() }
        }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation

        // Create a fresh AudioStreamTranscriber for each session.
        // State (confirmedSegments, etc.) does not reset between cycles,
        // so a new instance gives us a clean slate. This is cheap — it wraps
        // existing model references, no CoreML reload.
        //
        // WhisperKit's protocol types (AudioEncoding, etc.) are not Sendable.
        // We use nonisolated(unsafe) to cross the @MainActor → actor boundary.
        // This is safe because the WhisperKit pipeline is created once and
        // shared — we never mutate these references from multiple threads.
        nonisolated(unsafe) let encoder = pipe.audioEncoder
        nonisolated(unsafe) let extractor = pipe.featureExtractor
        nonisolated(unsafe) let seeker = pipe.segmentSeeker
        nonisolated(unsafe) let decoder = pipe.textDecoder
        nonisolated(unsafe) let tok = tokenizer
        nonisolated(unsafe) let processor = pipe.audioProcessor

        let ast = AudioStreamTranscriber(
            audioEncoder: encoder,
            featureExtractor: extractor,
            segmentSeeker: seeker,
            textDecoder: decoder,
            tokenizer: tok,
            audioProcessor: processor,
            decodingOptions: DecodingOptions(language: "en"),
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true,
            stateChangeCallback: { @Sendable [weak self] _, newState in
                // Extract Sendable values before crossing to MainActor.
                // State is structurally Sendable but not annotated as such.
                let confirmed = newState.confirmedSegments.map(\.text)
                let unconfirmed = newState.unconfirmedSegments.map(\.text)
                let currentText = newState.currentText
                let sampleCount = newState.lastBufferSize
                Task { @MainActor [weak self] in
                    self?.handleStateChange(
                        confirmedTexts: confirmed,
                        unconfirmedTexts: unconfirmed,
                        currentText: currentText,
                        sampleCount: sampleCount
                    )
                }
            }
        )
        self.transcriber = ast

        // startStreamTranscription() suspends for the entire recording —
        // handles mic permission, recording start, and realtime transcription
        // loop internally. This eliminates the stream-before-recording race.
        transcriptionTask = Task {
            self.isRecording = true
            logger.info("Recording started — AudioStreamTranscriber")
            do {
                try await ast.startStreamTranscription()
            } catch {
                logger.error("Stream transcription error: \(error)")
            }
            // Recording ended (either stopped or error)
            await MainActor.run {
                self.isRecording = false
                // Yield final transcript: confirmed + unconfirmed segments
                // (short utterances may only be in unconfirmed)
                self.yieldFinalTranscript()
                self.continuation?.finish()
                self.continuation = nil
                self.transcriber = nil
                logger.info("Recording session ended")
            }
        }

        return stream
        #endif
    }

    // MARK: - Stop Listening

    func stopListening() {
        guard isRecording || transcriptionTask != nil else { return }
        logger.info("stopListening")

        // Cancel the task (triggers CancellationError at suspension points)
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Stop the transcriber (tears down audio engine properly)
        let t = transcriber
        Task { await t?.stopStreamTranscription() }

        // Free audio buffer memory before LLM inference (peak memory consumer)
        nonisolated(unsafe) let processor = whisperPipe?.audioProcessor
        processor?.purgeAudioSamples(keepingLast: 0)
    }

    // MARK: - State Change Handling

    /// Called on every AudioStreamTranscriber state mutation.
    /// Combines confirmed + unconfirmed + current text for live partial results.
    private func handleStateChange(
        confirmedTexts: [String],
        unconfirmedTexts: [String],
        currentText: String,
        sampleCount: Int
    ) {
        // Filter "Waiting for speech..." placeholder
        let current = currentText == "Waiting for speech..." ? "" : currentText

        // Build transcript: confirmed (stable) + unconfirmed (fluctuating) + current (live)
        var parts: [String] = []
        let confirmed = confirmedTexts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmed.isEmpty { parts.append(confirmed) }
        let unconfirmed = unconfirmedTexts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !unconfirmed.isEmpty { parts.append(unconfirmed) }
        if !current.isEmpty { parts.append(current) }

        let transcript = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !transcript.isEmpty {
            partialTranscript = transcript
            continuation?.yield(transcript)
        }

        // Three-minute recording guard
        nonisolated(unsafe) let processor = whisperPipe?.audioProcessor
        if let processor, processor.audioSamples.count > maxRecordingSamples {
            logger.warning("Recording exceeded 3-minute cap — auto-stopping")
            stopListening()
        }
    }

    /// Yield the final combined transcript when recording ends.
    private func yieldFinalTranscript() {
        // partialTranscript already contains the latest combined text
        // from handleStateChange. Yield it one last time to ensure
        // the consumer gets the final version.
        if !partialTranscript.isEmpty {
            continuation?.yield(partialTranscript)
        }
    }
}

// MARK: - Errors

enum STTError: Error, LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone is not available. Please check permissions in Settings."
        }
    }
}
