import Foundation
import AVFoundation
import FluidAudio
import os

/// On-device speech-to-text using FluidAudio's Parakeet EOU streaming ASR.
@Observable
@MainActor
final class STTService {
    var isAuthorized: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""
    var error: String?
    var isASRReady: Bool { asrManager != nil }

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")

    nonisolated(unsafe) private var asrManager: StreamingEouAsrManager?

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<String>.Continuation?
    private var setupTask: Task<Void, Never>?

    init() {}

    // MARK: - Model Loading

    func loadASRModel() async {
        guard asrManager == nil else { return }
        do {
            print("[STT] Loading FluidAudio ASR model...")
            logger.fault("[STT] Loading FluidAudio ASR model...")
            let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
            try await manager.loadModelsFromHuggingFace()
            self.asrManager = manager
            print("[STT] ✅ ASR model loaded successfully")
            logger.fault("[STT] ✅ ASR model loaded successfully")
        } catch {
            print("[STT] ❌ Failed to load ASR model: \(error)")
            logger.fault("[STT] ❌ Failed to load ASR model: \(error)")
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
        print("[STT] Mic authorized: \(micGranted)")
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
        print("[STT] startListening() called, asrManager=\(asrManager != nil)")

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
        isRecording = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        let manager = asrManager
        let cont = continuation
        continuation = nil
        Task {
            do {
                let finalText = try await manager?.finish()
                print("[STT] finish() returned: '\(finalText ?? "nil")' (\(finalText?.count ?? 0) chars)")
                await MainActor.run {
                    if let finalText, !finalText.isEmpty {
                        self.partialTranscript = finalText
                        cont?.yield(finalText)
                    }
                    cont?.finish()
                }
            } catch {
                print("[STT] ❌ finish() failed: \(error)")
                await MainActor.run {
                    cont?.finish()
                }
            }
        }
    }

    // MARK: - Private: Async Recognition Setup

    private func startRecognitionAsync() async {
        guard !Task.isCancelled else {
            print("[STT] Setup cancelled before starting")
            return
        }

        print("[STT] startRecognitionAsync — asrManager=\(asrManager != nil)")

        guard let manager = asrManager else {
            print("[STT] ❌ ASR model not loaded — attempting retry")
            await loadASRModel()
            guard asrManager != nil else {
                print("[STT] ❌ Retry failed — ASR still nil")
                error = "Voice recognition not available. Please restart the app."
                continuation?.finish()
                return
            }
            await startRecognitionAsync()
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            guard audioSession.isInputAvailable else {
                throw STTError.microphoneUnavailable
            }

            if audioSession.category != .playAndRecord {
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [
                    .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP
                ])
            }
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("[STT] Audio session active, category=\(audioSession.category.rawValue)")

            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)

            // 1. Reset ASR state FIRST
            await manager.reset()
            print("[STT] ASR manager reset complete")

            // 2. Wire callbacks BEFORE audio starts
            await manager.setPartialCallback { [weak self] text in
                print("[STT] 📝 Partial callback fired: '\(text.prefix(50))...' (\(text.count) chars)")
                Task { @MainActor in
                    guard let self else { return }
                    self.partialTranscript = text
                    self.continuation?.yield(text)
                }
            }
            await manager.setEouCallback { text in
                print("[STT] 🔚 EOU callback fired: \(text.count) chars")
            }
            print("[STT] Callbacks wired")

            // 3. NOW start the audio engine and tap
            let engine = AVAudioEngine()
            self.audioEngine = engine

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            print("[STT] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch, \(inputFormat.commonFormat.rawValue)")

            nonisolated(unsafe) let unsafeManager = manager
            nonisolated(unsafe) var bufferCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
                bufferCount += 1
                let box = SendableBuffer(buffer)
                Task { try? await unsafeManager.process(audioBuffer: box.buffer) }
                // Log every ~5 seconds
                if bufferCount % 235 == 0 {
                    print("[STT] 🎤 Audio tap alive: \(bufferCount) buffers fed to ASR")
                }
            }

            engine.prepare()
            try engine.start()
            isRecording = true
            print("[STT] ✅ Recording started — engine running, tap installed")

        } catch {
            print("[STT] ❌ startRecognitionAsync failed: \(error)")
            self.error = "Failed to start recording: \(error.localizedDescription)"
            continuation?.finish()
        }
    }
}

// MARK: - Sendable Buffer Wrapper

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
