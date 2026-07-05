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

    /// Explicit, observable ASR-readiness state (replaces the fire-once boolean).
    /// Mic controls stay disabled until `.ready`; `.failed` is retriable.
    private(set) var asrState: ASRState = .idle

    /// First-run model download progress (0...1), driven by `WhisperKit.download`.
    private(set) var downloadProgress: Double = 0

    /// Voice recognition is usable only when the model is fully loaded.
    var isASRReady: Bool { asrState == .ready }

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    /// WhisperKit pipeline — created once at launch, persists across sessions.
    private var whisperPipe: WhisperKit?

    /// Test seam. When set (simulator/tests only), replaces the real download+load
    /// so the readiness state machine can be exercised without a CoreML model.
    /// Throwing from the closure drives the `.failed` branch; returning drives `.ready`.
    var loadOverrideForTesting: (@MainActor () async throws -> Void)?

    private var continuation: AsyncStream<String>.Continuation?
    private var transcriber: AudioStreamTranscriber?
    private var transcriptionTask: Task<Void, Never>?

    /// Maximum recording duration in samples (3 minutes at 16kHz).
    private let maxRecordingSamples = 16000 * 180

    // MARK: - Model Loading

    /// Download (with progress) and load the WhisperKit model, driving `asrState`.
    /// Idempotent for the terminal/ready and in-flight states; retriable from
    /// `.idle`/`.failed` (call again on the next voice-mode entry or `.active`).
    func loadASRModel() async {
        switch asrState {
        case .ready, .downloading, .loading:
            return  // already usable or a load is already in flight
        case .idle, .failed:
            break   // resting or previously failed — (re)attempt
        }

        do {
            try await performASRLoad()
            asrState = .ready
            logger.info("WhisperKit small.en ready")
        } catch is CancellationError {
            asrState = .idle
        } catch {
            logger.error("WhisperKit load failed: \(error)")
            asrState = .failed("Voice recognition failed to load. Tap to retry.")
        }
    }

    /// Performs the actual download + load. Split into two observable phases per
    /// KTD3: `WhisperKit.download` (with progress) then `WhisperKit(config)` load.
    private func performASRLoad() async throws {
        #if targetEnvironment(simulator)
        // No CoreML on the simulator. Honor an injected test loader if present so
        // the state machine is unit-testable; otherwise treat as ready immediately.
        asrState = .loading
        if let override = loadOverrideForTesting {
            try await override()
        }
        #else
        // 1. Download (surfaces progress, distinct from the compile/load phase).
        asrState = .downloading
        downloadProgress = 0
        let modelFolder = try await WhisperKit.download(
            variant: "small.en",
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }
        )

        // 2. Load + prewarm from the downloaded folder (no re-download). The init
        //    returning without throwing IS the authoritative "ready" signal.
        asrState = .loading
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: "small.en",
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        self.whisperPipe = pipe
        print("[STT] DIAG: WhisperKit loaded — tokenizer=\(pipe.tokenizer != nil), audioProcessor=\(type(of: pipe.audioProcessor))")
        #endif
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
        // Readiness gate (device + simulator): never start a recording before ASR is
        // ready. Surface a distinct message so an unready mic is not mistaken for an
        // empty transcript. Views also `.disabled` the mic until `.ready`.
        guard asrState == .ready else {
            self.error = "Preparing voice recognition…"
            logger.warning("startListening called while ASR not ready (state: \(String(describing: self.asrState)))")
            return AsyncStream<String> { $0.finish() }
        }
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
        guard let pipe = whisperPipe else {
            print("[STT] ❌ DIAG: whisperPipe is nil — model not loaded")
            self.error = "Voice recognition not available. Please restart."
            return AsyncStream<String> { $0.finish() }
        }
        guard let tokenizer = pipe.tokenizer else {
            print("[STT] ❌ DIAG: tokenizer is nil — pipe exists but tokenizer missing")
            self.error = "Voice recognition not available. Please restart."
            return AsyncStream<String> { $0.finish() }
        }
        print("[STT] DIAG: whisperPipe=OK, tokenizer=OK, creating AudioStreamTranscriber")

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
            print("[STT] DIAG: Task started, isRecording=true, calling startStreamTranscription...")
            do {
                try await ast.startStreamTranscription()
                print("[STT] DIAG: startStreamTranscription returned normally")
            } catch {
                print("[STT] ❌ DIAG: startStreamTranscription threw: \(error)")
            }
            // Recording ended (either stopped or error)
            print("[STT] DIAG: Cleaning up — partialTranscript='\(self.partialTranscript.prefix(40))'")
            await MainActor.run {
                self.isRecording = false
                self.yieldFinalTranscript()
                self.continuation?.finish()
                self.continuation = nil
                self.transcriber = nil
                print("[STT] DIAG: Recording session ended, isRecording=false")
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

// MARK: - ASR Readiness State

/// Observable readiness of the on-device speech recognizer (U2 state machine).
/// `.failed` carries a user-facing, retriable message.
enum ASRState: Equatable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)
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
