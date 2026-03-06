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

    // MARK: - Scene Phase Handling

    /// Call when the app returns to foreground to detect model eviction.
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard newPhase == .active else { return }

        Task {
            await downloader.recheckModelAvailability()
            syncFromDownloader()
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
