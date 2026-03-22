import Foundation
import AVFoundation
import FluidAudio
import UIKit
import os

/// Manages Kokoro neural TTS model download, loading, and audio synthesis.
/// Uses FluidAudio's CoreML-based Kokoro implementation for stable on-device inference.
@Observable
@MainActor
final class KokoroManager {
    // MARK: - State

    private(set) var phase: Phase = .idle
    private(set) var downloadProgress: Double = 0
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var cachedVoiceNames: [String] = []

    enum Phase: Sendable {
        case idle
        case downloading
        case compiling
        case loading
        case ready
        case failed
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Kokoro")

    /// nonisolated(unsafe) because KokoroTtsManager is not Sendable but we
    /// only access it from MainActor-isolated methods (sequential, no races).
    nonisolated(unsafe) private var ttsManager: KokoroTtsManager?

    /// AVAudioPlayer for playing WAV data returned by FluidAudio.
    /// Simpler than AVAudioEngine — FluidAudio returns complete WAV data.
    private var audioPlayer: AVAudioPlayer?

    /// Delegate that bridges AVAudioPlayer completion to async/await.
    private var playerDelegate: PlayerDelegate?

    private var downloadTask: Task<Void, Never>?

    /// Guards against concurrent loadEngine() calls.
    private var isLoading = false

    // MARK: - Computed Properties

    var isReady: Bool { phase == .ready }
    var isModelDownloaded: Bool { ttsManager?.isAvailable == true || modelsExistOnDisk }
    var availableVoices: [String] { cachedVoiceNames }

    /// Check if FluidAudio has cached models on disk.
    private var modelsExistOnDisk: Bool {
        guard let cacheDir = try? TtsModels.cacheDirectoryURL() else { return false }
        let modelsDir = cacheDir.appendingPathComponent(TtsConstants.defaultModelsSubdirectory)
        return FileManager.default.fileExists(atPath: modelsDir.path)
    }

    // MARK: - Static Properties (UserDefaults-backed)

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "kokoro_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "kokoro_enabled") }
    }

    static var selectedVoice: String {
        get { UserDefaults.standard.string(forKey: "kokoro_selected_voice") ?? TtsConstants.recommendedVoice }
        set { UserDefaults.standard.set(newValue, forKey: "kokoro_selected_voice") }
    }

    // MARK: - Download & Load Lifecycle

    func downloadModel() {
        guard downloadTask == nil else { return }
        errorMessage = nil
        phase = .downloading
        downloadProgress = 0
        statusMessage = "Starting download..."

        downloadTask = Task {
            do {
                // Download CoreML models with progress
                let models = try await TtsModels.download(
                    variants: [.fiveSecond, .fifteenSecond],
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.downloadProgress = progress.fractionCompleted
                            switch progress.phase {
                            case .listing:
                                self.statusMessage = "Finding models..."
                            case .downloading(let done, let total):
                                self.statusMessage = "Downloading (\(done)/\(total))..."
                                if self.phase != .downloading { self.phase = .downloading }
                            case .compiling(let name):
                                self.statusMessage = "Compiling \(name)..."
                                self.phase = .compiling
                            }
                        }
                    }
                )

                // Initialize TTS manager
                phase = .loading
                statusMessage = "Loading voice engine..."
                let manager = KokoroTtsManager(defaultVoice: Self.selectedVoice)
                try await manager.initialize(
                    models: models,
                    preloadVoices: [Self.selectedVoice]
                )

                ttsManager = manager
                populateVoiceNames()
                configureAudioSession()
                phase = .ready
                statusMessage = nil
                logger.info("FluidAudio Kokoro initialized successfully")

            } catch is CancellationError {
                phase = .idle
                statusMessage = nil
            } catch {
                logger.error("Kokoro setup failed: \(error)")
                errorMessage = error.localizedDescription
                phase = .failed
                statusMessage = nil
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .idle
        statusMessage = nil
    }

    func loadEngine() async {
        guard ttsManager == nil, !isLoading else {
            if ttsManager != nil { phase = .ready }
            return
        }
        guard MemoryMonitor.canLoadKokoro else {
            logger.warning("Skipping Kokoro load — memory pressure too high (\(MemoryMonitor.availableMB)MB available)")
            return
        }

        isLoading = true
        phase = .loading
        statusMessage = "Loading voice engine..."

        do {
            let manager = KokoroTtsManager(defaultVoice: Self.selectedVoice)
            // initialize() auto-downloads if models not cached
            try await manager.initialize(preloadVoices: [Self.selectedVoice])

            ttsManager = manager
            populateVoiceNames()
            configureAudioSession()
            phase = .ready
            statusMessage = nil
            logger.info("FluidAudio Kokoro loaded")
        } catch {
            logger.error("Kokoro load failed: \(error)")
            errorMessage = "Failed to load voice model: \(error.localizedDescription)"
            phase = .failed
            statusMessage = nil
        }
        isLoading = false
    }

    func unloadEngine() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        ttsManager?.cleanup()
        ttsManager = nil
        cachedVoiceNames = []
        if phase == .ready {
            phase = .idle
        }
        logger.info("Kokoro engine unloaded")
    }

    func deleteModel() {
        unloadEngine()
        // Clear FluidAudio's cached CoreML models
        if let cacheDir = try? TtsModels.cacheDirectoryURL() {
            try? FileManager.default.removeItem(at: cacheDir)
        }
        Self.isEnabled = false
        phase = .idle
        logger.info("Kokoro model cache deleted")
    }

    // MARK: - Synthesis & Playback

    func speak(_ text: String) async throws {
        guard ttsManager != nil else {
            throw KokoroError.engineNotLoaded
        }

        logger.info("Kokoro synthesis starting — text: \(text.prefix(80)), memory: \(MemoryMonitor.availableMB)MB")

        // Synthesize returns WAV-encoded Data at 24kHz.
        // Access ttsManager through nonisolated(unsafe) binding to cross
        // the @MainActor boundary into the async synthesize() call.
        nonisolated(unsafe) let unsafeManager = ttsManager!
        let voice = Self.selectedVoice
        let audioData = try await unsafeManager.synthesize(
            text: text,
            voice: voice,
            voiceSpeed: 1.0,
            variantPreference: .fifteenSecond,
            deEss: true
        )

        logger.info("Kokoro synthesis complete — \(audioData.count) bytes WAV")

        guard !audioData.isEmpty else {
            logger.warning("Kokoro returned empty audio data — skipping playback")
            return
        }

        // Play WAV data using AVAudioPlayer — much simpler than AVAudioEngine
        // since FluidAudio returns complete WAV-encoded Data.
        try await playWAVData(audioData)
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        // Resume any pending continuation so speak() returns
        playerDelegate?.forceComplete()
        playerDelegate = nil
    }

    // MARK: - Audio Playback

    private func playWAVData(_ data: Data) async throws {
        // Ensure audio session is active
        try? AVAudioSession.sharedInstance().setActive(true)

        let player = try AVAudioPlayer(data: data)

        // Use a delegate to bridge callback to async continuation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = PlayerDelegate {
                continuation.resume()
            }
            self.playerDelegate = delegate
            self.audioPlayer = player
            player.delegate = delegate
            player.play()
        }

        audioPlayer = nil
        playerDelegate = nil
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session configuration failed: \(error)")
        }
    }

    // MARK: - Voice Management

    private func populateVoiceNames() {
        // Filter to American English voices only (af_* and am_*)
        cachedVoiceNames = TtsConstants.availableVoices
            .filter { $0.hasPrefix("af_") || $0.hasPrefix("am_") }
            .map { String($0.dropFirst(3)) }  // Strip prefix for display
            .sorted()
    }

    // MARK: - Errors

    enum KokoroError: LocalizedError {
        case engineNotLoaded

        var errorDescription: String? {
            switch self {
            case .engineNotLoaded:
                return "Voice engine is not loaded."
            }
        }
    }
}

// MARK: - AVAudioPlayer Delegate Bridge

/// Bridges AVAudioPlayerDelegate's completion callback to async/await.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinished: @Sendable () -> Void
    private var completed = false

    init(onFinished: @escaping @Sendable () -> Void) {
        self.onFinished = onFinished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard !completed else { return }
        completed = true
        onFinished()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        guard !completed else { return }
        completed = true
        onFinished()
    }

    /// Force-complete the delegate (used by stopPlayback to resume the continuation).
    func forceComplete() {
        guard !completed else { return }
        completed = true
        onFinished()
    }
}
