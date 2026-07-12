import Foundation
import Hub
import MLXLMCommon
import MLXLLM
import Network
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
    /// Polls actual bytes on disk while downloading so progress reflects real
    /// transfer. The library's Progress reports file counts, not bytes, and
    /// stays flat during large single-file transfers — see startProgressPolling.
    private var progressPollTask: Task<Void, Never>?
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

    /// Which ModelOption is FULLY downloaded on disk, if any — directory present
    /// AND no `*.incomplete` blobs. A partial download is deliberately NOT cached,
    /// so relaunch resumes it (with progress) instead of loading a broken model.
    var cachedModelOption: ModelConfig.LLM.ModelOption? {
        guard let option = onDiskModelOption else { return nil }
        return Self.isModelDirComplete(modelDirectory(for: option)) ? option : nil
    }

    /// A ModelOption whose repo directory exists but is NOT yet complete — a
    /// download interrupted before finishing. Drives resume-with-progress on launch.
    var incompleteModelOption: ModelConfig.LLM.ModelOption? {
        guard let option = onDiskModelOption else { return nil }
        return Self.isModelDirComplete(modelDirectory(for: option)) ? nil : option
    }

    /// Any ModelOption whose repo directory exists on disk, complete or not.
    private var onDiskModelOption: ModelConfig.LLM.ModelOption? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hubDirectory.path) else { return nil }
        let contents = (try? fm.contentsOfDirectory(atPath: hubDirectory.path)) ?? []
        for option in ModelConfig.LLM.ModelOption.allCases {
            let expectedDir = "models--" + option.huggingFaceID.replacingOccurrences(of: "/", with: "--")
            if contents.contains(expectedDir) { return option }
        }
        return nil
    }

    /// Where launch should route based on what's on disk. Pure and testable —
    /// no MLX, so it runs on the simulator where the model calls cannot.
    enum LaunchRoute: Equatable, Sendable {
        case loadCached(ModelConfig.LLM.ModelOption)
        case resumeDownload(ModelConfig.LLM.ModelOption)
        case showPicker
    }

    /// A complete cache loads; else a partial resumes; else the picker shows.
    static func launchRoute(
        cached: ModelConfig.LLM.ModelOption?,
        incomplete: ModelConfig.LLM.ModelOption?
    ) -> LaunchRoute {
        if let cached { return .loadCached(cached) }
        if let incomplete { return .resumeDownload(incomplete) }
        return .showPicker
    }

    /// Start (or resume) the model download. Safe to call multiple times.
    func startDownload() {
        guard downloadTask == nil else { return }

        errorMessage = nil
        phase = .downloading
        progress = 0
        downloadedMB = 0
        let selected = ModelConfig.LLM.selectedModel
        totalMB = Double(selected.diskSizeMB)
        startProgressPolling(for: selected)

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
            stopProgressPolling()
            downloadTask = nil
        }
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressPolling()
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

        // LLMModelFactory handles HuggingFace download with resume support.
        // Progress is measured from actual bytes on disk by the poll task
        // (startProgressPolling), NOT from this callback: the library's Progress
        // counts files, not bytes, and stays flat during the large weights file.
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: hubAPI,
            configuration: configuration
        ) { _ in }

        try Task.checkCancellation()

        // Verification: the container loaded successfully, so the model is valid
        stopProgressPolling()
        phase = .verifying
        logger.info("Model downloaded and verified successfully")

        modelContainer = container
        progress = 1.0
        downloadedMB = totalMB
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

    // MARK: - Progress Measurement

    /// The hub directory holding every downloaded model repo.
    private var hubDirectory: URL {
        storage.modelsDirectory
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
    }

    /// The on-disk repo directory for a model option (may not exist yet).
    private func modelDirectory(for option: ModelConfig.LLM.ModelOption) -> URL {
        let dirName = "models--" + option.huggingFaceID.replacingOccurrences(of: "/", with: "--")
        return hubDirectory.appendingPathComponent(dirName)
    }

    /// Total bytes of all regular files under a model's repo directory, counting
    /// finalized blobs and `*.incomplete` partial blobs. Filesystem-only so it can
    /// run off the main actor. Returns 0 for an absent or empty directory.
    nonisolated static func modelDirectoryBytes(_ modelDir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: modelDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// True when a model's repo directory has no `*.incomplete` blob anywhere
    /// beneath it — i.e. every file finished downloading. HubApi/HubClient name
    /// partial LFS blobs `<etag>.incomplete` (removed on completion), so their
    /// absence means the download is done. Callers gate on directory existence
    /// first; an absent directory reports complete (no partials) but is never
    /// reached as a "cached" model without also existing on disk.
    nonisolated static func isModelDirComplete(_ modelDir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: modelDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return true }
        for case let url as URL in enumerator where url.pathExtension == "incomplete" {
            return false
        }
        return true
    }

    /// Poll the model's on-disk byte total ~2 Hz and publish real progress while
    /// downloading. The filesystem walk runs off the main actor; values are
    /// published monotonically so a transient blob rename can't move the bar back.
    private func startProgressPolling(for option: ModelConfig.LLM.ModelOption) {
        progressPollTask?.cancel()
        let modelDir = modelDirectory(for: option)
        let diskSizeMB = option.diskSizeMB
        progressPollTask = Task { [weak self] in
            while !Task.isCancelled {
                let bytes = await Task.detached(priority: .utility) {
                    Self.modelDirectoryBytes(modelDir)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.publishDownloadedBytes(bytes, diskSizeMB: diskSizeMB)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopProgressPolling() {
        progressPollTask?.cancel()
        progressPollTask = nil
    }

    /// Map on-disk bytes to a displayed (MB, fraction) pair. Non-decreasing in
    /// bytes and clamped to the size estimate so real bytes slightly over the
    /// estimate never render above 100%. Pure — no state, so it's unit-testable.
    nonisolated static func progressReadout(bytes: Int64, diskSizeMB: Int) -> (mb: Double, fraction: Double) {
        let totalMB = Double(diskSizeMB)
        let totalBytes = totalMB * 1_000_000
        let mb = min(Double(bytes) / 1_000_000, totalMB)
        let fraction = totalBytes > 0 ? min(Double(bytes) / totalBytes, 1.0) : 0
        return (mb, fraction)
    }

    /// Publish on-disk bytes, kept monotonic so a transient blob rename mid-poll
    /// can never move the readout backward.
    private func publishDownloadedBytes(_ bytes: Int64, diskSizeMB: Int) {
        let readout = Self.progressReadout(bytes: bytes, diskSizeMB: diskSizeMB)
        downloadedMB = max(downloadedMB, readout.mb)
        progress = max(progress, readout.fraction)
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

/// One-shot network-path check used to warn before a large download on an
/// expensive connection (cellular or personal hotspot). Kept in this file to
/// avoid an Xcode project-file edit; the project does not use synchronized groups.
enum NetworkStatus {
    /// Whether the current default path is expensive (cellular / hotspot), per
    /// `NWPath.isExpensive`. Awaits the monitor's first path update, then cancels.
    static func isCurrentPathExpensive() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let stream = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.isExpensive)
                continuation.finish()
            }
            monitor.start(queue: DispatchQueue(label: "com.lifehug.networkstatus"))
        }
        for await expensive in stream {
            return expensive
        }
        return false
    }
}
