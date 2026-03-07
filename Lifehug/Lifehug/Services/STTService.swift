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
    private var silenceTimer: Timer?
    private var continuation: AsyncStream<String>.Continuation?

    private let silenceTimeout: TimeInterval = 1.5

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
        let micGranted: Bool
        if #available(iOS 17, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        guard micGranted else {
            error = "Microphone access not authorized. Please enable in Settings."
            isAuthorized = false
            return
        }

        // Then request speech recognition permission
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        isAuthorized = (status == .authorized)
        if !isAuthorized {
            error = "Speech recognition not authorized. Please enable in Settings."
        }
        #endif
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

        let stream = AsyncStream<String> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
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
            continuation?.finish()
        }

        return stream
        #endif
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

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

        // Configure audio session
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Only require on-device if the recognizer supports it
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        // Install tap with nil format — lets the system use the hardware's native format.
        // Passing an explicit format can crash with NSException on format mismatch.
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        // Track accumulated transcript for iOS 18 non-cumulative results workaround
        nonisolated(unsafe) var accumulatedTranscript = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if text.count > accumulatedTranscript.count {
                    accumulatedTranscript = text
                }

                Task { @MainActor in
                    self.partialTranscript = accumulatedTranscript
                    self.resetSilenceTimer()

                    if result.isFinal {
                        self.continuation?.yield(accumulatedTranscript)
                        self.continuation?.finish()
                        self.stopListening()
                    }
                }
            }

            if let error {
                Task { @MainActor in
                    self.logger.error("Recognition error: \(error)")
                    if !accumulatedTranscript.isEmpty {
                        self.continuation?.yield(accumulatedTranscript)
                    }
                    self.continuation?.finish()
                    self.stopListening()
                }
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let transcript = self.partialTranscript
                if !transcript.isEmpty {
                    self.continuation?.yield(transcript)
                }
                self.continuation?.finish()
                self.stopListening()
            }
        }
    }
}

enum STTError: Error, LocalizedError {
    case recognizerUnavailable
    case notAuthorized
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device"
        case .notAuthorized:
            return "Speech recognition access not authorized"
        case .microphoneUnavailable:
            return "Microphone is not available. Please check permissions in Settings."
        }
    }
}
