import Foundation
import Speech
import AVFoundation
import os

@Observable
@MainActor
final class STTService {
    var isAuthorized: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""
    var error: String?

    private let logger = Logger(subsystem: "com.lifehug.app", category: "STT")
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<String>.Continuation?
    private var shouldKeepListening: Bool = false
    private var accumulatedTranscript: String = ""
    /// Shared reference accessible from the @Sendable audio tap callback.
    /// The tap outlives individual recognition requests during chaining.
    /// SAFETY: nonisolated(unsafe) is required because the audio tap callback runs on
    /// the real-time render thread (not the main actor). Writes only occur on @MainActor
    /// (startRecognition, chainRecognitionRequest, stopListening). The tap reads via
    /// optional chaining — a nil check races benignly.
    nonisolated(unsafe) private var sharedRequest: SFSpeechAudioBufferRecognitionRequest?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestAuthorization() async {
        #if targetEnvironment(simulator)
        // Simulator doesn't support on-device speech recognition.
        isAuthorized = true
        return
        #else
        // Request microphone permission first
        // IMPORTANT: Use nonisolated helpers to avoid Swift 6 @MainActor isolation
        // leaking into callback closures that run on background threads (TCC framework).
        let micGranted: Bool
        if #available(iOS 17, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await Self.requestMicPermission()
        }
        guard micGranted else {
            error = "Microphone access not authorized. Please enable in Settings."
            isAuthorized = false
            return
        }

        // Then request speech recognition permission
        let status = await Self.requestSpeechPermission()
        isAuthorized = (status == .authorized)
        if !isAuthorized {
            error = "Speech recognition not authorized. Please enable in Settings."
        }
        #endif
    }

    /// Wraps the callback-based speech authorization in a nonisolated context so the
    /// closure does NOT inherit @MainActor isolation. Without this, Swift 6 runtime
    /// enforcement crashes because TCC calls the callback on a background thread.
    private nonisolated static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Same pattern for microphone permission (pre-iOS 17 path).
    private nonisolated static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startListening() -> AsyncStream<String> {
        #if targetEnvironment(simulator)
        // Simulator has no microphone or on-device speech model.
        // Return a mock transcript after a short delay.
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
        // Clear any previous error
        self.error = nil
        self.accumulatedTranscript = ""
        self.shouldKeepListening = true

        let stream = AsyncStream<String> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.shouldKeepListening = false
                    self.stopListening()
                }
            }
        }

        do {
            try startRecognition()
        } catch {
            logger.error("Failed to start recognition: \(error)")
            self.error = "Failed to start speech recognition: \(error.localizedDescription)"
            isRecording = false
            shouldKeepListening = false
            continuation?.finish()
        }

        return stream
        #endif
    }

    func stopListening() {
        shouldKeepListening = false

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        sharedRequest = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        isRecording = false
    }

    private func startRecognition() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw STTError.recognizerUnavailable
        }

        // Verify microphone hardware is actually available
        let audioSession = AVAudioSession.sharedInstance()
        guard audioSession.isInputAvailable else {
            logger.error("No audio input available on this device")
            throw STTError.microphoneUnavailable
        }

        // Clean up any prior recognition state
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Configure audio session — use .default mode (not .measurement) for better TTS
        // quality and Bluetooth routing. Use both Bluetooth options for high-quality output.
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [
            .defaultToSpeaker,
            .allowBluetooth,
            .allowBluetoothA2DP
        ])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Require on-device recognition for privacy — memoir content must never leave the device.
        guard recognizer.supportsOnDeviceRecognition else {
            throw STTError.onDeviceUnavailable
        }

        let request = createRecognitionRequest()
        self.recognitionRequest = request
        self.sharedRequest = request

        // Install tap with nil format — lets the system use the hardware's native format.
        // Passing an explicit format can crash with NSException on format mismatch.
        let inputNode = engine.inputNode
        // Explicitly @Sendable to prevent @MainActor isolation inheritance.
        // This callback runs on the audio render thread.
        // Captures sharedRequest (nonisolated(unsafe)) so chained requests receive buffers.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
            self?.sharedRequest?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        installRecognitionTask(for: request)
    }

    /// Creates a new on-device speech recognition request.
    private func createRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        return request
    }

    /// Chains a new recognition request after the previous one timed out (~60s).
    /// The audio engine and tap keep running; only the request/task are replaced.
    private func chainRecognitionRequest() {
        logger.info("Chaining new recognition request (60s limit reached)")

        // Tear down old request/task without touching the audio engine
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        guard let recognizer, recognizer.isAvailable else {
            logger.error("Recognizer unavailable during chain — stopping")
            continuation?.finish()
            stopListening()
            return
        }

        let request = createRecognitionRequest()
        self.recognitionRequest = request
        self.sharedRequest = request

        installRecognitionTask(for: request)
    }

    /// Installs the recognition task callback for the given request.
    /// Handles partial results, final results, and the 60-second timeout error
    /// by chaining a new request when `shouldKeepListening` is still true.
    private func installRecognitionTask(for request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer else { return }

        // Snapshot the accumulated transcript so the @Sendable callback can build on it.
        // Uses a Sendable box because the recognition callback is @Sendable. The Speech
        // framework calls the callback serially, so no concurrent mutation occurs.
        let segment = SegmentState(base: self.accumulatedTranscript)

        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if text.count > segment.text.count {
                    segment.text = text
                }

                // Full transcript = everything from prior segments + this segment
                let fullTranscript: String
                if segment.base.isEmpty {
                    fullTranscript = segment.text
                } else {
                    fullTranscript = segment.base + " " + segment.text
                }
                let isFinal = result.isFinal

                Task { @MainActor in
                    self.accumulatedTranscript = fullTranscript
                    self.partialTranscript = fullTranscript
                    self.continuation?.yield(fullTranscript)

                    if isFinal {
                        if self.shouldKeepListening {
                            // 60s limit reached with a final result — chain a new request
                            self.chainRecognitionRequest()
                        } else {
                            self.continuation?.finish()
                            self.stopListening()
                        }
                    }
                }
            }

            if let error {
                // Check for the 60-second timeout error (kAFAssistantErrorDomain code 1110)
                let nsError = error as NSError
                let isTimeoutError = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110

                // Capture segment state before crossing isolation boundary
                let currentFull: String
                if segment.base.isEmpty {
                    currentFull = segment.text
                } else if segment.text.isEmpty {
                    currentFull = segment.base
                } else {
                    currentFull = segment.base + " " + segment.text
                }

                Task { @MainActor in
                    if isTimeoutError && self.shouldKeepListening {
                        // Timeout while still recording — chain seamlessly
                        self.accumulatedTranscript = currentFull
                        self.logger.info("60s timeout — chaining new recognition request")
                        self.chainRecognitionRequest()
                    } else {
                        self.logger.error("Recognition error: \(error)")
                        if !currentFull.isEmpty {
                            self.accumulatedTranscript = currentFull
                            self.partialTranscript = currentFull
                            self.continuation?.yield(currentFull)
                        }
                        self.continuation?.finish()
                        self.stopListening()
                    }
                }
            }
        }
    }

}

/// Thread-safe box for mutable transcript state shared with the @Sendable recognition callback.
/// Uses OSAllocatedUnfairLock for atomic access to the mutable text property.
/// Using @unchecked Sendable because the lock ensures thread safety.
private final class SegmentState: @unchecked Sendable {
    let base: String
    private let lock = OSAllocatedUnfairLock(initialState: "")

    init(base: String) {
        self.base = base
    }

    var text: String {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

enum STTError: Error, LocalizedError {
    case recognizerUnavailable
    case notAuthorized
    case microphoneUnavailable
    case onDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device"
        case .notAuthorized:
            return "Speech recognition access not authorized"
        case .microphoneUnavailable:
            return "Microphone is not available. Please check permissions in Settings."
        case .onDeviceUnavailable:
            return "On-device speech recognition is not available. Please use text input instead."
        }
    }
}
