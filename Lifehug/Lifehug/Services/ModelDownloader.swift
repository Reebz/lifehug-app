import Foundation
import Hub
import MLXLMCommon
import MLXLLM
import os

/// Downloads and verifies the on-device LLM using MLX Swift.
@Observable
@MainActor
final class ModelDownloader {
    // MARK: - Configuration

    /// Dynamic — reads the currently selected model. Do NOT capture as `let`.
    static var modelID: String { ModelConfig.LLM.modelID }

    // MARK: - Observable State

    private(set) var progress: Double = 0
    private(set) var downloadedMB: Double = 0
    private(set) var totalMB: Double = 0
    private(set) var phase: Phase = .idle
    private var lastProgressUpdate: Date = .distantPast
    private(set) var errorMessage: String?

    enum Phase: Sendable {
        case idle
        case downloading
        case verifying
        case ready
        case failed
    }

    // MARK: - Dependencies

    private let storage: StorageService
    private let logger = Logger(subsystem: "com.lifehug.app", category: "ModelDownloader")

    // MARK: - Internal

    /// The loaded model container, available after successful download + verification.
    private(set) var modelContainer: ModelContainer?
    private var downloadTask: Task<Void, Never>?
    /// In-flight cached-load, so concurrent callers (voice-entry background load, the
    /// pipeline's wait-for-ready gate, and the scene `.active` reload) coalesce onto a
    /// single load instead of each building a second container.
    private var loadTask: Task<Void, Never>?

    // MARK: - Init

    init(storage: StorageService = StorageService()) {
        self.storage = storage
    }

    // MARK: - Public API

    /// Whether the SELECTED model's files exist on disk.
    var isModelCached: Bool {
        cachedModelOption != nil && cachedModelOption == ModelConfig.LLM.selectedModel
    }

    /// Whether ANY model is cached on disk. Returns true even if the cached model
    /// differs from the selected one — used to skip the onboarding picker for returning users.
    var isAnyModelCached: Bool {
        cachedModelOption != nil
    }

    /// Which ModelOption is currently cached on disk, if any.
    /// Auto-syncs the selection to match whatever is actually on disk.
    var cachedModelOption: ModelConfig.LLM.ModelOption? {
        let hubDir = storage.modelsDirectory
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
        let fm = FileManager.default
        guard fm.fileExists(atPath: hubDir.path) else { return nil }
        let contents = (try? fm.contentsOfDirectory(atPath: hubDir.path)) ?? []
        for option in ModelConfig.LLM.ModelOption.allCases {
            let expectedDir = "models--" + option.huggingFaceID.replacingOccurrences(of: "/", with: "--")
            if contents.contains(where: { $0 == expectedDir }) {
                return option
            }
        }
        return nil
    }

    /// Start (or resume) the model download. Safe to call multiple times.
    func startDownload() {
        guard downloadTask == nil else { return }

        errorMessage = nil
        phase = .downloading
        progress = 0

        downloadTask = Task {
            do {
                try await performDownload()
            } catch is CancellationError {
                logger.info("Download cancelled")
                phase = .idle
            } catch {
                logger.error("Download failed: \(error.localizedDescription)")
                errorMessage = Self.userFacingMessage(for: error)
                phase = .failed
            }
            downloadTask = nil
        }
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Attempt to load an already-downloaded model (e.g. on subsequent launches).
    func loadCachedModel() async {
        // Coalesce concurrent loads onto one task (check-and-set is atomic on the
        // MainActor — no await between the guard and the assignment).
        if let loadTask {
            await loadTask.value
            return
        }
        guard modelContainer == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            self.phase = .verifying
            do {
                let container = try await self.loadModel()
                self.modelContainer = container
                self.phase = .ready
            } catch {
                self.logger.warning("Cached model failed to load: \(error.localizedDescription)")
                // Do NOT delete the model on a load failure. A transient Metal/memory error
                // or a background-during-load is recoverable, but deleting forced a
                // multi-hundred-MB re-download AND a permanent voice-mode dead-end (the load
                // paths can load but never download). Keep the files; a later trigger retries.
                // Genuinely-corrupt models are still removable via deleteCache() in Settings.
                self.phase = .idle
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Delete cached model files and reset to idle state.
    func deleteCache() {
        cancelDownload()
        clearModelFiles()
        modelContainer = nil
        phase = .idle
    }

    /// Release the in-memory model to free RAM when backgrounded.
    /// Files stay on disk — model reloads on next foreground.
    func unloadModel() {
        guard phase == .ready else { return }
        modelContainer = nil
        phase = .idle
        logger.info("Model unloaded to free memory")
    }

    /// Re-check model availability (e.g. after returning from background).
    /// iOS can evict large files under memory pressure.
    func recheckModelAvailability() async {
        guard phase == .ready else { return }
        if !isModelCached {
            logger.warning("Model files evicted while backgrounded")
            modelContainer = nil
            phase = .idle
        }
    }

    // MARK: - Orphan Sweep

    /// Hub directory names for repo IDs retired by the model-tier swap, using the
    /// same "models--" + repo ID with "/" → "--" naming as `cachedModelOption`.
    /// Explicit allowlist — never "anything outside allCases" — so an unexpected
    /// directory is never destroyed. models--mlx-community--Llama-3.2-3B-Instruct-4bit
    /// is deliberately absent: it is the Quality tier's revert asset and is retained
    /// until the device pass confirms the 4B tier.
    nonisolated static let orphanedModelDirNames = [
        "models--mlx-community--Llama-3.2-1B-Instruct-4bit",
        "models--mlx-community--SmolLM3-3B-3bit",
    ]

    /// Sweep weights for retired repo IDs (~2 GB across the old Fast/Balanced dirs)
    /// so they don't strand on returning users' devices. The deletes run off the
    /// MainActor — awaited so launch routing still happens strictly after the sweep,
    /// but without blocking the main thread on the filesystem walk.
    func sweepOrphanedModels() async {
        let hubDir = storage.modelsDirectory
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
        await Task.detached(priority: .utility) {
            Self.sweepOrphanedModels(hubDirectory: hubDir)
        }.value
    }

    /// Core sweep logic — takes the hub directory so tests can point it at a
    /// temp dir. Idempotent: absent directories are a no-op, never an error.
    nonisolated static func sweepOrphanedModels(hubDirectory: URL) {
        let logger = Logger(subsystem: "com.lifehug.app", category: "ModelDownloader")
        let fm = FileManager.default
        for dirName in orphanedModelDirNames {
            let dir = hubDirectory.appendingPathComponent(dirName)
            guard fm.fileExists(atPath: dir.path) else { continue }
            do {
                try fm.removeItem(at: dir)
                logger.info("Swept orphaned model directory: \(dirName)")
            } catch {
                logger.error("Failed to sweep orphaned model directory \(dirName): \(error)")
            }
        }
    }

    // MARK: - Private

    private func performDownload() async throws {
        // Network reachability check
        guard isNetworkLikelyAvailable() else {
            throw DownloadError.noNetwork
        }

        // Disk space check — size varies by selected model
        try checkDiskSpace(requiredMB: ModelConfig.LLM.selectedModel.diskSizeMB)

        let configuration = ModelConfiguration(
            id: Self.modelID
        )

        let hubAPI = HubApi(downloadBase: storage.modelsDirectory)

        logger.info("Starting model download: \(Self.modelID)")

        // LLMModelFactory handles HuggingFace download with resume support
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: hubAPI,
            configuration: configuration
        ) { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                // Throttle UI updates to ~10 Hz to avoid excessive SwiftUI redraws
                let now = Date()
                guard now.timeIntervalSince(self.lastProgressUpdate) >= 0.1
                      || progress.fractionCompleted >= 1.0 else { return }
                self.lastProgressUpdate = now
                self.progress = progress.fractionCompleted
                self.downloadedMB = Double(progress.completedUnitCount) / 1_000_000
                self.totalMB = Double(progress.totalUnitCount) / 1_000_000
            }
        }

        try Task.checkCancellation()

        // Verification: the container loaded successfully, so the model is valid
        phase = .verifying
        logger.info("Model downloaded and verified successfully")

        modelContainer = container
        progress = 1.0
        phase = .ready
    }

    private func loadModel() async throws -> ModelContainer {
        let configuration = ModelConfiguration(
            id: Self.modelID
        )

        let hubAPI = HubApi(downloadBase: storage.modelsDirectory)

        return try await LLMModelFactory.shared.loadContainer(
            hub: hubAPI,
            configuration: configuration
        ) { _ in }
    }

    private func clearModelFiles() {
        let hubDir = storage.modelsDirectory.appendingPathComponent("huggingface")
        let fm = FileManager.default
        if fm.fileExists(atPath: hubDir.path) {
            do {
                try fm.removeItem(at: hubDir)
                logger.info("Cleared model files at: \(hubDir.path)")
            } catch {
                logger.error("Failed to clear model files: \(error)")
            }
        } else {
            logger.info("No model files to clear at: \(hubDir.path)")
        }
    }

    // MARK: - Checks

    private func isNetworkLikelyAvailable() -> Bool {
        // Simple DNS-based check. NWPathMonitor requires import Network and
        // async setup; a synchronous hostname lookup is sufficient for a
        // pre-flight gate.
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo("huggingface.co", "443", &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
    }

    private func checkDiskSpace(requiredMB: Int) throws {
        let url = storage.modelsDirectory
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        let availableMB = availableBytes / 1_000_000
        if availableMB < Int64(requiredMB) {
            throw DownloadError.insufficientDiskSpace(
                availableMB: Int(availableMB),
                requiredMB: requiredMB
            )
        }
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case noNetwork
        case insufficientDiskSpace(availableMB: Int, requiredMB: Int)
        case modelCorrupted

        var errorDescription: String? {
            switch self {
            case .noNetwork:
                return "No internet connection. Please connect to Wi-Fi or cellular data and try again."
            case .insufficientDiskSpace(let available, let required):
                return "Not enough storage space. \(required - available) MB more needed. Free up space and try again."
            case .modelCorrupted:
                return "The downloaded model appears corrupted. It will be removed so you can try again."
            }
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let dlError = error as? DownloadError {
            return dlError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "Connection lost. Lifehug will resume the download automatically when you reconnect."
            case NSURLErrorTimedOut:
                return "The download timed out. Please check your connection and try again."
            case NSURLErrorCancelled:
                return "Download was cancelled."
            default:
                return "A network error occurred: \(error.localizedDescription)"
            }
        }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
