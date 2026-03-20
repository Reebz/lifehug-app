import Foundation
import AVFoundation
import CryptoKit
@preconcurrency import MLX
@preconcurrency import KokoroSwift
@preconcurrency import MLXUtilsLibrary
import Synchronization
import UIKit
import os

/// Manages Kokoro neural TTS model download, loading, and audio synthesis.
@Observable
@MainActor
final class KokoroManager {
    // MARK: - State

    private(set) var phase: Phase = .idle
    private(set) var downloadProgress: Double = 0
    private(set) var errorMessage: String?
    private(set) var cachedVoiceNames: [String] = []

    enum Phase: Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Kokoro")
    /// Thread-safe container for engine state that crosses isolation boundaries to Task.detached.
    /// Using @unchecked Sendable because the Mutex ensures exclusive access.
    private struct EngineState: @unchecked Sendable {
        var ttsEngine: KokoroTTS?
        var voices: [String: MLXArray] = [:]
    }
    private let engineState = Mutex(EngineState())
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    /// Retains the current audio buffer until playback completes (prevents use-after-free).
    private var currentBuffer: AVAudioPCMBuffer?
    private var downloadTask: Task<Void, Never>?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var routeChangeObserver: (any NSObjectProtocol)?
    private var mediaResetObserver: (any NSObjectProtocol)?
    /// Guards against concurrent loadEngine() calls (safe as plain Bool because class is @MainActor).
    private var isLoading = false

    // MARK: - File Locations

    private static let modelFileName = ModelConfig.Kokoro.modelFileName
    private static let voicesFileName = ModelConfig.Kokoro.voicesFileName

    private var kokoroDir: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable — iOS sandbox is broken")
        }
        let dir = appSupport.appendingPathComponent("kokoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var modelFileURL: URL {
        kokoroDir.appendingPathComponent(Self.modelFileName)
    }

    private var voicesFileURL: URL {
        // Prefer bundled voices (always available, no download needed)
        if let bundled = Bundle.main.url(forResource: "voices", withExtension: "npz") {
            return bundled
        }
        // Fallback to downloaded (legacy path)
        return kokoroDir.appendingPathComponent(Self.voicesFileName)
    }

    // MARK: - Public API

    var isModelDownloaded: Bool {
        // Voices are bundled in the app, so only the model file needs to be downloaded
        FileManager.default.fileExists(atPath: modelFileURL.path)
    }

    var isReady: Bool { phase == .ready }

    var availableVoices: [String] {
        cachedVoiceNames
    }

    /// Selected voice identifier (stored in UserDefaults).
    static var selectedVoice: String {
        get { UserDefaults.standard.string(forKey: "kokoro_selected_voice") ?? "af_heart" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoro_selected_voice") }
    }

    /// Whether Kokoro TTS is enabled (user preference).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "kokoro_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "kokoro_enabled") }
    }

    // MARK: - Download

    func downloadModel() {
        guard downloadTask == nil else { return }
        errorMessage = nil
        phase = .downloading
        downloadProgress = 0

        downloadTask = Task {
            do {
                try await performDownload()
                await loadEngine()
            } catch is CancellationError {
                phase = .idle
            } catch {
                logger.error("Kokoro download failed: \(error)")
                errorMessage = error.localizedDescription
                phase = .failed
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        // Clean up any partial model download
        if !isModelDownloaded {
            try? FileManager.default.removeItem(at: modelFileURL)
        }
        phase = .idle
    }

    /// Load engine from already-downloaded files.
    func loadEngine() async {
        guard !isLoading else { return }
        guard isModelDownloaded else {
            phase = .idle
            return
        }
        guard engineState.withLock({ $0.ttsEngine }) == nil else {
            phase = .ready
            return
        }

        // Check memory before loading ~80MB model
        guard MemoryMonitor.canLoadKokoro else {
            logger.warning("Skipping Kokoro load — memory pressure too high (\(MemoryMonitor.availableMB)MB available)")
            return
        }

        isLoading = true
        defer { isLoading = false }

        phase = .loading
        do {
            // Load model on a background thread (heavy computation)
            let modelURL = modelFileURL
            let voicesURL = voicesFileURL

            let (engine, loadedVoices) = try await Task.detached {
                let eng = KokoroTTS(modelPath: modelURL)
                let vcs = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
                return (eng, vcs)
            }.value

            guard !loadedVoices.isEmpty else {
                throw KokoroError.voicesEmpty
            }

            engineState.withLock { state in
                state.ttsEngine = engine
                state.voices = loadedVoices
            }
            cachedVoiceNames = loadedVoices.keys.map { String($0.split(separator: ".")[0]) }.sorted()
            setupAudioEngine()
            phase = .ready
            logger.info("Kokoro engine loaded with \(loadedVoices.count) voices")
        } catch {
            logger.error("Kokoro engine load failed: \(error)")
            errorMessage = "Failed to load voice model: \(error.localizedDescription)"
            phase = .failed
        }
    }

    func unloadEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        for observer in [interruptionObserver, routeChangeObserver, mediaResetObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = nil
        routeChangeObserver = nil
        mediaResetObserver = nil
        currentBuffer = nil
        audioEngine = nil
        playerNode = nil
        engineState.withLock { state in
            state.ttsEngine = nil
            state.voices = [:]
        }
        cachedVoiceNames = []
        if phase == .ready {
            phase = .idle
        }
        logger.info("Kokoro engine unloaded")
    }

    func deleteModel() {
        unloadEngine()
        try? FileManager.default.removeItem(at: kokoroDir)
        Self.isEnabled = false
        phase = .idle
        logger.info("Kokoro model files deleted")
    }

    // MARK: - Synthesis

    /// Synthesize and play a sentence. Returns when playback completes.
    /// Throws if synthesis fails (OOM, corrupted model, GPU error).
    func speak(_ text: String) async throws {
        let (engine, voiceEmbedding) = try engineState.withLock { state -> (KokoroTTS, MLXArray) in
            guard let engine = state.ttsEngine else {
                throw KokoroError.engineNotLoaded
            }
            let voiceKey = Self.selectedVoice + ".npy"
            guard let embedding = state.voices[voiceKey] else {
                throw KokoroError.voiceNotFound(Self.selectedVoice)
            }
            return (engine, embedding)
        }

        // Determine language from voice prefix
        let language: Language = Self.selectedVoice.hasPrefix("b") ? .enGB : .enUS

        logger.info("Kokoro synthesis starting — available memory: \(MemoryMonitor.availableMB)MB, text length: \(text.count)")

        let (audio, _) = try await Task.detached {
            try engine.generateAudio(voice: voiceEmbedding, language: language, text: text, speed: 1.1)
        }.value

        logger.info("Kokoro synthesis complete — \(audio.count) samples, available memory: \(MemoryMonitor.availableMB)MB")

        await playAudio(audio)
    }


    /// Stop any current playback.
    func stopPlayback() {
        playerNode?.stop()
    }

    // MARK: - Audio Playback

    private func setupAudioEngine() {
        // Configure audio session for both recording and playback — use .playAndRecord
        // everywhere so STT and TTS share the same category. This eliminates the crash
        // caused by category switching between .playAndRecord (STT) and .playback (TTS).
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session setup failed: \(error)")
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            logger.error("Failed to create audio format for sample rate \(sampleRate)")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            logger.error("Audio engine initial start failed: \(error)")
        }

        audioEngine = engine
        playerNode = player
        observeAudioInterruptions()
        observeRouteChanges()
        observeMediaServicesReset()
    }

    private func observeAudioInterruptions() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { @Sendable [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    self.logger.info("Audio interruption — stopping Kokoro playback")
                    self.playerNode?.stop()
                case .ended:
                    // Reactivate audio session and restart engine after interruption
                    // (phone call, Siri). Category is already .playAndRecord.
                    try? AVAudioSession.sharedInstance().setActive(true)
                    if let engine = self.audioEngine, !engine.isRunning {
                        try? engine.start()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func observeRouteChanges() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { @Sendable [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let reasonValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                if reason == .oldDeviceUnavailable {
                    // Bluetooth device disconnected mid-playback — stop player so the
                    // continuation resumes naturally. The engine adapts to the new route
                    // (built-in speaker) on next engine.start().
                    self.logger.info("Audio route changed — device disconnected, stopping playback")
                    self.playerNode?.stop()
                }
            }
        }
    }

    private func observeMediaServicesReset() {
        if let observer = mediaResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.warning("Media services reset — recreating audio engine")
                self.playerNode?.stop()
                self.currentBuffer = nil
                self.audioEngine = nil
                self.playerNode = nil
                self.setupAudioEngine()
            }
        }
    }

    private func playAudio(_ samples: [Float]) async {
        guard let engine = audioEngine, let player = playerNode else { return }

        // Validate samples before scheduling on the audio engine.
        // NaN/Inf values from Kokoro's neural decoder crash the audio render thread
        // (native crash with no Swift error handling). Empty samples crash buffer creation.
        guard !samples.isEmpty else {
            logger.warning("playAudio: empty sample array — skipping")
            return
        }
        let hasInvalidSamples = samples.contains(where: { $0.isNaN || $0.isInfinite })
        if hasInvalidSamples {
            logger.error("playAudio: samples contain NaN or Inf — skipping to prevent audio crash")
            return
        }

        logger.info("playAudio: \(samples.count) samples, engine.isRunning=\(engine.isRunning)")

        // Ensure audio session is active — it may have been deactivated by
        // VoicePipeline.stopAll() or an interruption handler.
        try? AVAudioSession.sharedInstance().setActive(true)

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            logger.error("Failed to create audio format")
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            logger.error("Failed to create audio buffer")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        guard let channelData = buffer.floatChannelData?[0] else {
            logger.error("Failed to get float channel data from buffer")
            return
        }
        samples.withUnsafeBufferPointer { src in
            guard let baseAddress = src.baseAddress else { return }
            channelData.initialize(from: baseAddress, count: samples.count)
        }

        // Retain buffer until playback completes
        currentBuffer = buffer

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.error("Audio engine start failed: \(error)")
                currentBuffer = nil
                return
            }
        }

        // nonisolated(unsafe): AVAudioPlayerNode/AVAudioPCMBuffer are non-Sendable Apple
        // framework types. Safe here because playback is serialized on MainActor and we
        // only read these inside the completion callback (which runs on an internal audio thread).
        nonisolated(unsafe) let unsafePlayer = player
        nonisolated(unsafe) let unsafeBuffer = buffer
        // Shared state for double-resume guard and cancellation safety.
        // The continuation reference is stored in the lock so onCancel can resume it,
        // preventing the fatal "leaked continuation" trap when withTimeout cancels the task.
        let state = OSAllocatedUnfairLock(initialState: PlaybackState())
        do {
            try await withTimeout(seconds: 15) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        state.withLock { $0.continuation = continuation }
                        unsafePlayer.scheduleBuffer(unsafeBuffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                            state.withLock { s in
                                guard !s.resumed else { return }
                                s.resumed = true
                                let cont = s.continuation
                                s.continuation = nil
                                Task { @MainActor in cont?.resume() }
                            }
                        }
                        unsafePlayer.play()
                    }
                } onCancel: {
                    state.withLock { s in
                        guard !s.resumed else { return }
                        s.resumed = true
                        let cont = s.continuation
                        s.continuation = nil
                        Task { @MainActor in cont?.resume() }
                    }
                }
            }
        } catch is TimeoutError {
            logger.warning("Audio playback timed out after 15s — stopping player")
            player.stop()
        } catch {
            logger.error("Audio playback error: \(error)")
        }

        logger.info("playAudio: completed")
        currentBuffer = nil
    }

    // MARK: - Legacy Cleanup

    /// Remove legacy downloaded voices.npz (now bundled in the app).
    private func cleanupLegacyVoices() {
        let legacy = kokoroDir.appendingPathComponent(Self.voicesFileName)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
            logger.info("Removed legacy downloaded voices.npz")
        }
    }

    // MARK: - Download Implementation

    private func performDownload() async throws {
        // Prevent device sleep during large download
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
        }

        // Download model safetensors from HuggingFace (~160 MB)
        // Voices are bundled in the app — no download needed
        downloadProgress = 0.05
        if !FileManager.default.fileExists(atPath: modelFileURL.path) {
            try await downloadFile(from: ModelConfig.Kokoro.modelDownloadURL, to: modelFileURL, label: "model")
        }
        downloadProgress = 0.95

        // Clean up any legacy downloaded voices (now bundled)
        cleanupLegacyVoices()

        downloadProgress = 1.0
    }

    private func downloadFile(from url: URL, to destination: URL, label: String) async throws {
        // Clean up any partial/leftover file from a previous failed download
        try? FileManager.default.removeItem(at: destination)

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await downloadFileOnce(from: url, to: destination, label: label)
                return  // success
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            } catch {
                lastError = error
                // Clean up partial download
                try? FileManager.default.removeItem(at: destination)
                logger.warning("Kokoro \(label) download attempt \(attempt + 1)/3 failed: \(error)")

                if attempt < 2 {
                    try await Task.sleep(for: .seconds(2))
                    try Task.checkCancellation()
                }
            }
        }
        throw lastError ?? KokoroError.downloadFailed("unknown")
    }

    private func downloadFileOnce(from url: URL, to destination: URL, label: String) async throws {
        logger.info("Downloading Kokoro \(label) from \(url)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 300

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Clean up the temp file from URLSession
            try? FileManager.default.removeItem(at: tempURL)
            throw KokoroError.downloadFailed(label)
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Verify SHA-256 integrity if a real hash is configured
        let expectedHash = ModelConfig.Kokoro.modelSHA256

        if expectedHash == "PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD" {
            logger.warning("Model integrity verification disabled — SHA-256 placeholder in use for \(label)")
        } else {
            // Stream hash computation in 1MB chunks to avoid 160MB memory spike
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let chunk = handle.readData(ofLength: 1_048_576)
                guard !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            let digest = hasher.finalize()
            let actualHash = digest.map { String(format: "%02x", $0) }.joined()

            if actualHash != expectedHash {
                try? FileManager.default.removeItem(at: destination)
                logger.error("SHA-256 mismatch for \(label): expected \(expectedHash), got \(actualHash)")
                throw KokoroError.integrityCheckFailed(label)
            }
            logger.info("Kokoro \(label) SHA-256 verified")
        }

        logger.info("Kokoro \(label) downloaded successfully")
    }

    // MARK: - Playback State

    /// Shared state for audio playback continuation safety.
    /// Stored inside OSAllocatedUnfairLock so both the scheduleBuffer callback
    /// and withTaskCancellationHandler's onCancel can resume the continuation.
    private struct PlaybackState: @unchecked Sendable {
        var resumed = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    // MARK: - Errors

    enum KokoroError: LocalizedError {
        case engineNotLoaded
        case voiceNotFound(String)
        case downloadFailed(String)
        case voicesEmpty
        case integrityCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .engineNotLoaded:
                return "Voice engine is not loaded."
            case .voiceNotFound(let voice):
                return "Voice '\(voice)' not found."
            case .downloadFailed(let file):
                return "Failed to download Kokoro \(file). Please check your connection."
            case .voicesEmpty:
                return "Voice data file is empty or corrupted."
            case .integrityCheckFailed(let file):
                return "Integrity check failed for Kokoro \(file). The download may be corrupted."
            }
        }
    }
}
