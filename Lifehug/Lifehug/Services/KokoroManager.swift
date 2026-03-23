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
        get {
            let stored = UserDefaults.standard.string(forKey: "kokoro_selected_voice") ?? TtsConstants.recommendedVoice
            // Validate against known voices — corrupted values (e.g., "bella" without
            // the "af_" prefix) cause FluidAudio download failures.
            if TtsConstants.availableVoices.contains(stored) {
                return stored
            }
            return TtsConstants.recommendedVoice
        }
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
        errorMessage = nil
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
        // Clean up legacy MLX model files (Application Support/kokoro/)
        // from pre-FluidAudio builds. The ~697MB safetensors file persists
        // on devices that had the MLX version installed.
        cleanupLegacyMLXFiles()
        Self.isEnabled = false
        Self.selectedVoice = TtsConstants.recommendedVoice  // Reset to af_heart
        phase = .idle
        errorMessage = nil
        logger.info("Kokoro model cache deleted")
    }

    /// Auto-clean legacy files on first launch after migration. Safe to call multiple times.
    func cleanupLegacyFilesIfNeeded() {
        cleanupLegacyMLXFiles()
    }

    /// Remove legacy MLX Kokoro model files from Application Support/kokoro/.
    /// These are from the pre-FluidAudio build and are no longer needed.
    private func cleanupLegacyMLXFiles() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let legacyDir = appSupport.appendingPathComponent("kokoro", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.removeItem(at: legacyDir)
            logger.info("Removed legacy MLX kokoro directory (\(legacyDir.path))")
        }
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
        // Keep full voice IDs (af_heart, am_adam, etc.) — FluidAudio needs them
        // for voice embedding downloads. Stripping the prefix causes 404 errors.
        cachedVoiceNames = TtsConstants.availableVoices
            .filter { $0.hasPrefix("af_") || $0.hasPrefix("am_") }
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
/// Uses OSAllocatedUnfairLock for thread-safe double-resume guard since
/// audioPlayerDidFinishPlaying fires on an AVFoundation background thread
/// while forceComplete() fires from @MainActor.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinished: @Sendable () -> Void
    private let completed = OSAllocatedUnfairLock(initialState: false)

    init(onFinished: @escaping @Sendable () -> Void) {
        self.onFinished = onFinished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        complete()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        complete()
    }

    /// Force-complete the delegate (used by stopPlayback to resume the continuation).
    func forceComplete() {
        complete()
    }

    private func complete() {
        completed.withLock { done in
            guard !done else { return }
            done = true
            onFinished()
        }
    }
}
