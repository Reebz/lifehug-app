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
        #if targetEnvironment(simulator)
        // MLX requires a real Metal GPU — the simulator will crash during model init.
        // Skip download/load entirely and let the app run with mock LLM responses.
        status = .ready
        isLoaded = true
        return
        #else
        // One-time sweep of weights retired by the model-tier swap, before the
        // cached-model check so stale directories never influence launch routing.
        downloader.sweepOrphanedModels()

        // If any model is cached, auto-set the selection to match and load it.
        // This handles returning users and skips the model picker.
        if let cached = downloader.cachedModelOption {
            ModelConfig.LLM.selectedModel = cached
            status = .loading
            await downloader.loadCachedModel()
            syncFromDownloader()

            if downloader.phase == .ready {
                return
            }
            // If loading failed, the files are KEPT (no auto-delete) and phase reset to
            // .idle → syncFromDownloader shows .notDownloaded; tapping Download re-verifies
            // and resumes the existing files rather than forcing a full re-download.
        }
        // Not yet downloaded; stay at .notDownloaded and let user tap Download.
        // Read the selection once so a legacy persisted rawValue is migrated to
        // its tier before the download screen (or any later reader) sees it.
        _ = ModelConfig.LLM.selectedModel
        syncFromDownloader()
        #endif
    }

    // MARK: - Download Control

    /// Trigger a model download (called from UI).
    func triggerDownload() {
        downloader.startDownload()
        startSyncingState()
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
