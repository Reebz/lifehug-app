import Foundation
import AVFoundation
import CryptoKit
@preconcurrency import MLX
@preconcurrency import KokoroSwift
@preconcurrency import MLXUtilsLibrary
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
    // SAFETY: nonisolated(unsafe) is needed because KokoroTTS and MLXArray are not
    // Sendable but must cross isolation boundaries to Task.detached for heavy computation.
    // All mutations occur on @MainActor (loadEngine, unloadEngine, deleteModel).
    // Reads in Task.detached (speak, loadEngine) await completion before the next mutation.
    nonisolated(unsafe) private var ttsEngine: KokoroTTS?
    nonisolated(unsafe) private var voices: [String: MLXArray] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var downloadTask: Task<Void, Never>?

    // MARK: - File Locations

    private static let modelFileName = ModelConfig.Kokoro.modelFileName
    private static let voicesFileName = ModelConfig.Kokoro.voicesFileName

    private var kokoroDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        guard isModelDownloaded else {
            phase = .idle
            return
        }
        guard ttsEngine == nil else {
            phase = .ready
            return
        }

        // Check memory before loading ~80MB model
        guard MemoryMonitor.canLoadKokoro else {
            logger.warning("Skipping Kokoro load — memory pressure too high (\(MemoryMonitor.availableMB)MB available)")
            return
        }

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

            ttsEngine = engine
            voices = loadedVoices
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
        audioEngine = nil
        playerNode = nil
        ttsEngine = nil
        voices = [:]
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
        guard let engine = ttsEngine else {
            throw KokoroError.engineNotLoaded
        }

        let voiceKey = Self.selectedVoice + ".npy"
        guard let voiceEmbedding = voices[voiceKey] else {
            logger.warning("Voice '\(Self.selectedVoice)' not found")
            throw KokoroError.voiceNotFound(Self.selectedVoice)
        }

        // Determine language from voice prefix
        let language: Language = Self.selectedVoice.hasPrefix("b") ? .enGB : .enUS

        let (audio, _) = try await Task.detached {
            try engine.generateAudio(voice: voiceEmbedding, language: language, text: text)
        }.value

        await playAudio(audio)
    }


    /// Stop any current playback.
    func stopPlayback() {
        playerNode?.stop()
    }

    // MARK: - Audio Playback

    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroTTS.Constants.samplingRate), channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            logger.error("Audio engine initial start failed: \(error)")
        }

        audioEngine = engine
        playerNode = player
    }

    private func playAudio(_ samples: [Float]) async {
        guard let engine = audioEngine, let player = playerNode else { return }

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            logger.error("Failed to create audio buffer")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        let dst = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            guard let baseAddress = src.baseAddress else { return }
            dst.initialize(from: baseAddress, count: samples.count)
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.error("Audio engine start failed: \(error)")
                return
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { _ in
                resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return }
                    alreadyResumed = true
                    Task { @MainActor in
                        continuation.resume()
                    }
                }
            }
            player.play()
        }
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
        throw lastError!
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

        if expectedHash != "PLACEHOLDER_COMPUTE_ON_FIRST_DOWNLOAD" {
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
