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

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    /// The FluidAudio ASR manager — created once, reused across sessions via reset().
    /// nonisolated(unsafe) because StreamingEouAsrManager is an actor and we access it
    /// from @MainActor methods via await. No concurrent access.
    nonisolated(unsafe) private var asrManager: StreamingEouAsrManager?

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<String>.Continuation?

    init() {}

    // MARK: - Model Loading

    /// Load the ASR model. Call once at app launch — the manager persists and is
    /// reused across recording sessions via reset().
    func loadASRModel() async {
        guard asrManager == nil else { return }
        do {
            let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
            try await manager.loadModelsFromHuggingFace()
            self.asrManager = manager
            logger.info("FluidAudio ASR model loaded")
        } catch {
            logger.error("Failed to load ASR model: \(error)")
            // Not fatal — we'll try again on first startListening()
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        #if targetEnvironment(simulator)
        isAuthorized = true
        return
        #else
        // Only microphone permission needed — FluidAudio runs on-device, no Speech framework.
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

        do {
            try startRecognition()
        } catch {
            logger.error("Failed to start recognition: \(error)")
            self.error = "Failed to start speech recognition: \(error.localizedDescription)"
            isRecording = false
            continuation?.finish()
        }

        return stream
        #endif
    }

    // MARK: - Stop Listening

    func stopListening(reason: String = "unknown") {
        guard isRecording else { return }
        logger.info("stopListening — reason: \(reason)")

        // Stop audio capture
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Get final transcript from ASR (fire-and-forget — partial callback already yielded it)
        let manager = asrManager
        Task {
            let finalText = try? await manager?.finish()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let finalText, !finalText.isEmpty {
                    self.partialTranscript = finalText
                    self.continuation?.yield(finalText)
                }
                self.continuation?.finish()
                self.continuation = nil
            }
        }

        isRecording = false
    }

    // MARK: - Private: Start Recognition

    private func startRecognition() throws {
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

        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Reset ASR manager for new session (models stay loaded)
        let manager = asrManager
        Task { await manager?.reset() }

        // Wire FluidAudio callbacks
        Task {
            // Partial callback — fires on each 160ms chunk when new tokens are decoded
            await manager?.setPartialCallback { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.partialTranscript = text
                    self.continuation?.yield(text)
                }
            }

            // EOU callback — fires on utterance boundaries. Log but don't auto-stop.
            await manager?.setEouCallback { [weak self] text in
                Task { @MainActor in
                    self?.logger.info("EOU detected: \(text.count) chars")
                }
            }
        }

        // Audio tap — copies the buffer and sends to the ASR actor.
        // AVAudioPCMBuffer is non-Sendable so we wrap in a Sendable box.
        let inputNode = engine.inputNode
        nonisolated(unsafe) let unsafeManager = asrManager
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
            let box = SendableBuffer(buffer)
            Task { try? await unsafeManager?.process(audioBuffer: box.buffer) }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        logger.info("Recording started with FluidAudio ASR")
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
