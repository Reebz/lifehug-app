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
        if downloader.isModelCached {
            // Model files exist — try to load from cache
            status = .loading
            await downloader.loadCachedModel()
            syncFromDownloader()

            if downloader.phase == .ready {
                return
            }
            // If loading failed, downloader cleared the files and reset to .idle,
            // which syncFromDownloader mapped to .notDownloaded — user must re-download.
        }
        // Not yet downloaded; stay at .notDownloaded and let user tap Download.
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
        syncFromDownloader()
    }

    // MARK: - Scene Phase Handling

    /// Handle scene phase transitions — unload model on background, reload on active.
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            downloader.unloadModel()
            isLoaded = false
            status = .notDownloaded
        case .active:
            Task {
                await downloader.recheckModelAvailability()
                syncFromDownloader()
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
