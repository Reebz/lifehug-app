import Foundation
import AVFoundation
@preconcurrency import MLX
@preconcurrency import KokoroSwift
@preconcurrency import MLXUtilsLibrary
import os

/// Manages Kokoro neural TTS model download, loading, and audio synthesis.
@Observable
@MainActor
final class KokoroManager {
    // MARK: - State

    private(set) var phase: Phase = .idle
    private(set) var downloadProgress: Double = 0
    private(set) var errorMessage: String?

    enum Phase: Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Kokoro")
    nonisolated(unsafe) private var ttsEngine: KokoroTTS?
    nonisolated(unsafe) private var voices: [String: MLXArray] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var downloadTask: Task<Void, Never>?

    /// Callback when the current utterance finishes playing.
    var onUtteranceFinished: (@MainActor () -> Void)?

    // MARK: - File Locations

    private static let modelFileName = "kokoro-v1_0.safetensors"
    private static let voicesFileName = "voices.npz"

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
        kokoroDir.appendingPathComponent(Self.voicesFileName)
    }

    // MARK: - Public API

    var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFileURL.path) &&
        FileManager.default.fileExists(atPath: voicesFileURL.path)
    }

    var isReady: Bool { phase == .ready }

    var availableVoices: [String] {
        voices.keys.map { String($0.split(separator: ".")[0]) }.sorted()
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
    func speak(_ text: String) async {
        guard let engine = ttsEngine else { return }

        let voiceKey = Self.selectedVoice + ".npy"
        guard let voiceEmbedding = voices[voiceKey] else {
            logger.warning("Voice '\(Self.selectedVoice)' not found, falling back")
            return
        }

        // Determine language from voice prefix
        let language: Language = Self.selectedVoice.hasPrefix("b") ? .enGB : .enUS

        do {
            let (audio, _) = try await Task.detached {
                try engine.generateAudio(voice: voiceEmbedding, language: language, text: text)
            }.value

            await playAudio(audio)
        } catch {
            logger.error("Kokoro synthesis failed: \(error)")
        }
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

        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            logger.error("Audio engine start failed: \(error)")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
                Task { @MainActor [weak self] in
                    self?.onUtteranceFinished?()
                    continuation.resume()
                }
            }
            player.play()
        }
    }

    // MARK: - Download Implementation

    private func performDownload() async throws {
        // Download model safetensors from HuggingFace (~160 MB)
        if !FileManager.default.fileExists(atPath: modelFileURL.path) {
            let modelURL = URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors")!
            try await downloadFile(from: modelURL, to: modelFileURL, label: "model")
        }
        downloadProgress = 0.7

        // Download voices.npz from KokoroTestApp via Git LFS (~14.6 MB)
        if !FileManager.default.fileExists(atPath: voicesFileURL.path) {
            let voicesURL = URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/voices.npz")!
            try await downloadFile(from: voicesURL, to: voicesFileURL, label: "voices")
        }
        downloadProgress = 1.0
    }

    private func downloadFile(from url: URL, to destination: URL, label: String) async throws {
        logger.info("Downloading Kokoro \(label) from \(url)")

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw KokoroError.downloadFailed(label)
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        logger.info("Kokoro \(label) downloaded successfully")
    }

    // MARK: - Errors

    enum KokoroError: LocalizedError {
        case downloadFailed(String)
        case voicesEmpty

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let file):
                return "Failed to download Kokoro \(file). Please check your connection."
            case .voicesEmpty:
                return "Voice data file is empty or corrupted."
            }
        }
    }
}
