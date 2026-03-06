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
        recognizer?.supportsOnDeviceRecognition = true
    }

    func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        isAuthorized = (status == .authorized)
        if !isAuthorized {
            error = "Speech recognition not authorized. Please enable in Settings."
        }
    }

    func startListening() -> AsyncStream<String> {
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
            continuation?.finish()
        }

        return stream
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

        isRecording = false
    }

    private func startRecognition() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw STTError.recognizerUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        // Track accumulated transcript for iOS 18 non-cumulative results workaround
        var accumulatedTranscript = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                // iOS 18 workaround: results may be non-cumulative
                // Use the longer of accumulated vs new result
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

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device"
        case .notAuthorized:
            return "Speech recognition access not authorized"
        }
    }
}
