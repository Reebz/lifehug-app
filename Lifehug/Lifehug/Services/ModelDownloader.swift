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

    static let modelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"

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

    // MARK: - Init

    init(storage: StorageService = StorageService()) {
        self.storage = storage
    }

    // MARK: - Public API

    /// Whether the model files exist on disk (quick check, does not verify integrity).
    var isModelCached: Bool {
        // HubApi stores downloads in {downloadBase}/huggingface/hub/models--{org}--{model}/
        let hubDir = storage.modelsDirectory
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
        let fm = FileManager.default
        guard fm.fileExists(atPath: hubDir.path) else { return false }
        // Check if there's at least one model directory inside
        let contents = (try? fm.contentsOfDirectory(atPath: hubDir.path)) ?? []
        return contents.contains { $0.hasPrefix("models--") }
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
        guard modelContainer == nil else { return }
        phase = .verifying
        do {
            let container = try await loadModel()
            modelContainer = container
            phase = .ready
        } catch {
            logger.warning("Cached model failed to load: \(error.localizedDescription)")
            // Model is likely corrupted — clear and require re-download
            clearModelFiles()
            phase = .idle
        }
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

    // MARK: - Private

    private func performDownload() async throws {
        // Network reachability check
        guard isNetworkLikelyAvailable() else {
            throw DownloadError.noNetwork
        }

        // Disk space check (need ~1 GB for the 1B-4bit model)
        try checkDiskSpace(requiredMB: 1024)

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
        try? FileManager.default.removeItem(at: hubDir)
        logger.info("Cleared model files for re-download")
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
