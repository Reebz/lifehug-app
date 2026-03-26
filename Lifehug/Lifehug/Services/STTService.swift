import Foundation
import AVFoundation
import WhisperKit
import os

/// On-device speech-to-text using WhisperKit (OpenAI Whisper via CoreML).
/// Uses WhisperKit's built-in AudioProcessor for recording (handles hardware
/// format detection, resampling to 16kHz mono, and proper engine teardown).
/// Transcribes periodically (~3s) for live partial results, and does a final
/// full-buffer transcription on stop.
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
    private var setupTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    init() {}

    // MARK: - Model Loading

    func loadASRModel() async {
        guard whisperPipe == nil else { return }
        do {
            print("[STT] Loading WhisperKit small.en model...")
            let pipe = try await WhisperKit(WhisperKitConfig(
                model: "small.en",
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            ))
            self.whisperPipe = pipe
            print("[STT] ✅ WhisperKit loaded successfully")
        } catch {
            print("[STT] ❌ WhisperKit load failed: \(error)")
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
        print("[STT] startListening() — whisperPipe=\(whisperPipe != nil)")

        let stream = AsyncStream<String> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.stopListening(reason: "stream onTermination")
                }
            }
        }

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
        print("[STT] stopListening — reason: \(reason)")

        setupTask?.cancel()
        setupTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isRecording = false

        // Grab accumulated samples BEFORE stopping the recorder
        nonisolated(unsafe) let processor = whisperPipe?.audioProcessor
        let samples: [Float]
        if let processor {
            samples = Array(processor.audioSamples)
        } else {
            samples = []
        }

        // Use WhisperKit's proper engine teardown (removeTap, disconnect, stop, reset)
        processor?.stopRecording()

        // Final transcription of complete audio buffer
        let cont = continuation
        continuation = nil

        print("[STT] stopListening — \(samples.count) samples captured (\(String(format: "%.1f", Double(samples.count) / 16000))s)")

        if !samples.isEmpty, let pipe = whisperPipe {
            nonisolated(unsafe) let unsafePipe = pipe
            Task {
                do {
                    print("[STT] Final transcription: \(samples.count) samples")
                    let results = try await unsafePipe.transcribe(audioArray: samples)
                    let text = results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    print("[STT] Final result: '\(text.prefix(80))...' (\(text.count) chars)")
                    await MainActor.run {
                        if !text.isEmpty {
                            self.partialTranscript = text
                            cont?.yield(text)
                        }
                        cont?.finish()
                    }
                } catch {
                    print("[STT] ❌ Final transcription failed: \(error)")
                    await MainActor.run { cont?.finish() }
                }
            }
        } else {
            print("[STT] ⚠️ No samples captured — nothing to transcribe")
            cont?.finish()
        }
    }

    // MARK: - Private: Async Recognition Setup

    private func startRecognitionAsync() async {
        guard !Task.isCancelled else { return }

        // Ensure WhisperKit is loaded
        if whisperPipe == nil {
            print("[STT] WhisperKit not loaded — attempting load")
            await loadASRModel()
            guard whisperPipe != nil else {
                print("[STT] ❌ WhisperKit still nil after retry")
                error = "Voice recognition not available. Please restart."
                continuation?.finish()
                return
            }
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            guard audioSession.isInputAvailable else {
                throw STTError.microphoneUnavailable
            }

            // Set audio session for both recording and playback (TTS)
            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [
                    .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP
                ])
            }
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Use WhisperKit's AudioProcessor for recording. It:
            // 1. Taps at the hardware's native sample rate (not 16kHz)
            // 2. Resamples to 16kHz mono via AVAudioConverter in the tap callback
            // 3. Accumulates samples in audioProcessor.audioSamples
            // Our previous approach of installing a tap directly at 16kHz silently
            // failed to deliver buffers on some devices (WhisperKit issue #261).
            guard let processor = whisperPipe?.audioProcessor else {
                throw STTError.microphoneUnavailable
            }
            nonisolated(unsafe) let unsafeProcessor = processor
            try unsafeProcessor.startRecordingLive(callback: nil)

            isRecording = true
            print("[STT] ✅ Recording started — WhisperKit AudioProcessor (hardware format → 16kHz resample)")

            // Start periodic transcription task (~every 3 seconds)
            startPeriodicTranscription()

        } catch {
            print("[STT] ❌ startRecognitionAsync failed: \(error)")
            self.error = "Failed to start recording: \(error.localizedDescription)"
            continuation?.finish()
        }
    }

    /// Periodically transcribes accumulated audio for live partial results.
    private func startPeriodicTranscription() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                guard let self else { continue }
                guard let pipe = self.whisperPipe else { continue }
                nonisolated(unsafe) let unsafePipe = pipe

                // Read accumulated samples from WhisperKit's AudioProcessor
                let samples = Array(unsafePipe.audioProcessor.audioSamples)
                guard samples.count > 16000 else { continue } // Need at least 1 second of audio

                do {
                    let results = try await unsafePipe.transcribe(audioArray: samples)
                    let text = results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty {
                        await MainActor.run {
                            self.partialTranscript = text
                            self.continuation?.yield(text)
                        }
                        print("[STT] 📝 Partial (\(samples.count) samples): '\(text.prefix(60))...'")
                    }
                } catch {
                    print("[STT] Periodic transcription error: \(error)")
                }
            }
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
