import Foundation
import AVFoundation
import FluidAudio
import os

/// On-device speech-to-text using FluidAudio's Parakeet EOU streaming ASR.
/// Replaces Apple's SFSpeechRecognizer — no 60-second limit, no aggressive endpointing.
@Observable
@MainActor
final class STTService {
    var isAuthorized: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""
    var error: String?
    /// Whether the ASR model is loaded and ready for recording.
    var isASRReady: Bool { asrManager != nil }

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    /// The FluidAudio ASR manager — created once, reused across sessions via reset().
    nonisolated(unsafe) private var asrManager: StreamingEouAsrManager?

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<String>.Continuation?
    private var setupTask: Task<Void, Never>?

    init() {}

    // MARK: - Model Loading

    /// Load the ASR model. Call at app launch — the manager persists across sessions.
    func loadASRModel() async {
        guard asrManager == nil else { return }
        do {
            logger.info("Loading FluidAudio ASR model...")
            let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
            try await manager.loadModelsFromHuggingFace()
            self.asrManager = manager
            logger.info("FluidAudio ASR model loaded successfully")
        } catch {
            logger.error("Failed to load ASR model: \(error)")
            self.error = "Voice recognition model failed to download. Check your connection and restart."
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

        let stream = AsyncStream<String> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.stopListening(reason: "stream onTermination")
                }
            }
        }

        // Start recognition in a Task so we can await the async ASR setup
        // (reset + callback wiring) BEFORE starting the audio engine.
        // Store the task so stopListening() can cancel it if called before setup completes.
        setupTask = Task {
            await self.startRecognitionAsync()
            self.setupTask = nil
        }

        return stream
        #endif
    }

    // MARK: - Stop Listening

    func stopListening(reason: String = "unknown") {
        guard isRecording || setupTask != nil else { return }
        logger.info("stopListening — reason: \(reason)")

        // Cancel the setup task if it hasn't finished yet (prevents engine
        // starting after stopListening was called — race condition H1)
        setupTask?.cancel()
        setupTask = nil

        isRecording = false

        // Stop audio capture
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Get final transcript from ASR (fire-and-forget — partial callback already yielded it)
        let manager = asrManager
        let cont = continuation
        continuation = nil
        Task {
            let finalText = try? await manager?.finish()
            await MainActor.run {
                if let finalText, !finalText.isEmpty {
                    self.partialTranscript = finalText
                    cont?.yield(finalText)
                }
                cont?.finish()
            }
        }
    }

    // MARK: - Private: Async Recognition Setup

    /// Sets up the ASR manager, wires callbacks, THEN starts the audio engine.
    /// This ensures callbacks are registered before any audio buffers arrive.
    private func startRecognitionAsync() async {
        // Check if stopListening() was called before we started
        guard !Task.isCancelled else {
            logger.info("Setup cancelled before starting")
            return
        }

        // Guard: ASR model must be loaded
        guard let manager = asrManager else {
            logger.error("ASR model not loaded — attempting retry")
            await loadASRModel()
            guard asrManager != nil else {
                error = "Voice recognition not available. Please restart the app."
                continuation?.finish()
                return
            }
            // Retry with the now-loaded manager
            await startRecognitionAsync()
            return
        }

        do {
            // Verify microphone hardware
            let audioSession = AVAudioSession.sharedInstance()
            guard audioSession.isInputAvailable else {
                throw STTError.microphoneUnavailable
            }

            // Ensure audio session is configured for recording
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [
                    .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP
                ])
            }
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Clean up prior state
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)

            // 1. Reset ASR state FIRST (await — not fire-and-forget)
            await manager.reset()

            // 2. Wire callbacks BEFORE starting audio (await — not fire-and-forget)
            await manager.setPartialCallback { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.partialTranscript = text
                    self.continuation?.yield(text)
                }
            }
            await manager.setEouCallback { [weak self] text in
                Task { @MainActor in
                    self?.logger.info("EOU detected: \(text.count) chars")
                }
            }

            // 3. NOW start the audio engine and tap
            let engine = AVAudioEngine()
            self.audioEngine = engine

            let inputNode = engine.inputNode
            nonisolated(unsafe) let unsafeManager = manager
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
                let box = SendableBuffer(buffer)
                Task { try? await unsafeManager.process(audioBuffer: box.buffer) }
            }

            engine.prepare()
            try engine.start()
            isRecording = true
            logger.info("Recording started with FluidAudio ASR")

        } catch {
            logger.error("Failed to start recognition: \(error)")
            self.error = "Failed to start recording: \(error.localizedDescription)"
            continuation?.finish()
        }
    }
}

// MARK: - Sendable Buffer Wrapper

/// Wraps AVAudioPCMBuffer (non-Sendable) for crossing actor boundaries.
/// Safe because each buffer is created fresh in the audio tap and consumed once.
private struct SendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

// MARK: - Errors

enum STTError: Error, LocalizedError {
    case microphoneUnavailable
    case asrNotLoaded

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone is not available. Please check permissions in Settings."
        case .asrNotLoaded:
            return "Speech recognition model not loaded. Please restart the app."
        }
    }
}
