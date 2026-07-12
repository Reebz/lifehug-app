import SwiftUI
import MLXLMCommon

@Observable
@MainActor
final class ModelState {
    var downloadProgress: Double = 0
    var downloadedMB: Double = 0
    var totalMB: Double = 0
    var status: ModelStatus = .notDownloaded
    var isLoaded: Bool = false

    /// Set when a download is waiting on the user's confirmation to proceed over
    /// an expensive (cellular / hotspot) connection. Drives the LaunchView alert.
    var pendingCellularConfirm: Bool = false

    /// The loaded model container, available once status == .ready.
    var modelContainer: ModelContainer? {
        downloader.modelContainer
    }

    enum ModelStatus {
        case notDownloaded
        case downloading
        case loading
        case ready
        case error(String)
    }

    // MARK: - Private

    private let downloader = ModelDownloader()
    private var syncTask: Task<Void, Never>?

    // MARK: - Launch

    /// Called once from LaunchView's .task to set up the initial state.
    func prepareOnLaunch() async {
        // One-time sweep of weights retired by the model-tier swap, before the
        // on-disk checks so stale directories never influence launch routing.
        await downloader.sweepOrphanedModels()

        #if targetEnvironment(simulator)
        // MLX requires a real Metal GPU — the simulator will crash during model init.
        // Skip download/load entirely and let the app run with mock LLM responses.
        status = .ready
        isLoaded = true
        return
        #else
        // Route from what is actually on disk: a complete cache loads; a partial
        // download resumes WITH progress (not the silent load path that showed a
        // bare spinner "stuck at 0%"); nothing on disk shows the picker.
        switch ModelDownloader.launchRoute(
            cached: downloader.cachedModelOption,
            incomplete: downloader.incompleteModelOption
        ) {
        case .loadCached(let option):
            ModelConfig.LLM.selectedModel = option
            status = .loading
            await downloader.loadCachedModel()
            syncFromDownloader()
            if downloader.phase == .ready { return }
            // Load failed: files are KEPT (no auto-delete); reset to .notDownloaded
            // so tapping Download re-verifies and resumes rather than re-downloading.
            _ = ModelConfig.LLM.selectedModel
            syncFromDownloader()

        case .resumeDownload(let option):
            ModelConfig.LLM.selectedModel = option
            await requestDownload()

        case .showPicker:
            // Read the selection once so a legacy persisted rawValue is migrated to
            // its tier before the download screen (or any later reader) sees it.
            _ = ModelConfig.LLM.selectedModel
            syncFromDownloader()
        }
        #endif
    }

    // MARK: - Download Control

    /// Trigger a model download (called from UI).
    func triggerDownload() {
        downloader.startDownload()
        startSyncingState()
    }

    /// Whether starting a download now needs the user's OK first.
    enum DownloadGate: Equatable, Sendable {
        case proceed
        case confirmCellular(sizeMB: Int)
    }

    /// Pure decision: an expensive path defers to a confirmation; otherwise proceed.
    nonisolated static func downloadGate(isExpensive: Bool, sizeMB: Int) -> DownloadGate {
        isExpensive ? .confirmCellular(sizeMB: sizeMB) : .proceed
    }

    /// Start a download, first confirming on an expensive (cellular / hotspot)
    /// connection so a multi-hundred-MB transfer never begins silently on data.
    /// Used by the Download button, Try Again, and the launch resume path.
    func requestDownload() async {
        let expensive = await NetworkStatus.isCurrentPathExpensive()
        applyDownloadGate(Self.downloadGate(isExpensive: expensive, sizeMB: ModelConfig.LLM.selectedModel.diskSizeMB))
    }

    /// Apply a gate decision. Separated from the async network check so it is
    /// testable without a live connection.
    func applyDownloadGate(_ gate: DownloadGate) {
        switch gate {
        case .proceed:
            triggerDownload()
        case .confirmCellular:
            pendingCellularConfirm = true
        }
    }

    /// User accepted the cellular warning — proceed with the download.
    func confirmCellularDownload() {
        pendingCellularConfirm = false
        triggerDownload()
    }

    /// User declined the cellular warning — leave the files on disk for a later
    /// Wi-Fi resume and return to the current (non-downloading) state.
    func cancelCellularDownload() {
        pendingCellularConfirm = false
        syncFromDownloader()
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloader.cancelDownload()
        syncFromDownloader()
    }

    /// Delete cached model files and reset to not-downloaded state.
    func deleteModelCache() {
        downloader.deleteCache()
        ModelConfig.LLM.clearSelection()  // Reset so model picker re-appears
        syncFromDownloader()
    }

    /// Ensure the model container is loaded via the single downloader-owned path.
    /// Idempotent (no-op if already loaded or not cached). LLMService.loadModel()
    /// delegates here so the LLM consumer never builds a second container (U7 / R6).
    func ensureModelLoaded() async {
        #if targetEnvironment(simulator)
        return
        #else
        guard !isLoaded, downloader.isModelCached else { return }
        status = .loading
        await downloader.loadCachedModel()
        syncFromDownloader()
        #endif
    }

    // MARK: - Scene Phase Handling

    /// Handle scene phase transitions — unload model on background, reload on active.
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            downloader.unloadModel()
            isLoaded = false
            // Do NOT set status = .notDownloaded — files are still on disk.
            // Keep the current status (usually .ready) so the UI doesn't
            // show a download prompt when the app returns to foreground.
        case .active:
            if !isLoaded && downloader.isModelCached {
                status = .loading
                Task {
                    await downloader.loadCachedModel()
                    syncFromDownloader()
                }
            }
        default:
            break
        }
    }

    // MARK: - State Sync

    /// Continuously sync observable state from the downloader while downloading.
    private func startSyncingState() {
        syncTask?.cancel()
        syncTask = Task {
            while !Task.isCancelled {
                syncFromDownloader()
                if downloader.phase == .ready || downloader.phase == .failed || downloader.phase == .idle {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Pull downloader state into ModelState's published properties.
    private func syncFromDownloader() {
        downloadProgress = downloader.progress
        downloadedMB = downloader.downloadedMB
        totalMB = downloader.totalMB

        switch downloader.phase {
        case .idle:
            status = .notDownloaded
            isLoaded = false
        case .downloading:
            status = .downloading
            isLoaded = false
        case .verifying:
            status = .loading
            isLoaded = false
        case .ready:
            status = .ready
            isLoaded = true
        case .failed:
            status = .error(downloader.errorMessage ?? "An unknown error occurred.")
            isLoaded = false
        }
    }
}
