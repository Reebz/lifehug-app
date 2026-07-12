import Testing
import Foundation
@testable import Lifehug

@Suite("ModelDownloader")
@MainActor
struct ModelDownloaderTests {

    // The sweep's core logic takes the hub directory as a parameter, so these
    // tests point it at a temp directory instead of the app's real model storage.

    private static let retiredFast = "models--mlx-community--Llama-3.2-1B-Instruct-4bit"
    private static let retiredBalanced = "models--mlx-community--SmolLM3-3B-3bit"
    /// KTD8's Quality revert asset — must survive the sweep until the device
    /// pass confirms the 4B tier.
    private static let retainedQualityRevert = "models--mlx-community--Llama-3.2-3B-Instruct-4bit"
    private static let currentQuality = "models--mlx-community--gemma-3-text-4b-it-4bit"

    /// Builds a temp hub dir containing the given model dirs (each with a file
    /// inside, so removal is proven for non-empty dirs), runs body, cleans up.
    private func withHubDirectory(
        containing dirNames: [String],
        _ body: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let hubDir = fm.temporaryDirectory
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: hubDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: hubDir) }
        for name in dirNames {
            let dir = hubDir.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        }
        try body(hubDir)
    }

    private func exists(_ name: String, in hubDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: hubDir.appendingPathComponent(name).path)
    }

    // MARK: - Orphan Sweep

    @Test("Allowlist contains exactly the two retired dirs — never the Quality revert asset")
    func allowlistIsExactlyTheTwoRetiredDirs() {
        #expect(ModelDownloader.orphanedModelDirNames.sorted() == [
            Self.retiredFast,
            Self.retiredBalanced,
        ].sorted())
        #expect(!ModelDownloader.orphanedModelDirNames.contains(Self.retainedQualityRevert))
    }

    @Test("Allowlisted old dirs are removed; a current-model dir is untouched")
    func sweepRemovesRetiredDirsOnly() throws {
        try withHubDirectory(containing: [Self.retiredFast, Self.retiredBalanced, Self.currentQuality]) { hubDir in
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)

            #expect(!exists(Self.retiredFast, in: hubDir))
            #expect(!exists(Self.retiredBalanced, in: hubDir))
            #expect(exists(Self.currentQuality, in: hubDir))
        }
    }

    @Test("The retained Llama-3.2-3B revert asset is NOT removed")
    func sweepKeepsQualityRevertAsset() throws {
        try withHubDirectory(containing: [Self.retiredFast, Self.retainedQualityRevert]) { hubDir in
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)

            #expect(!exists(Self.retiredFast, in: hubDir))
            #expect(exists(Self.retainedQualityRevert, in: hubDir))
        }
    }

    @Test("No old dirs present is a no-op without error")
    func sweepNoOpWhenNothingToRemove() throws {
        try withHubDirectory(containing: [Self.currentQuality]) { hubDir in
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)

            #expect(exists(Self.currentQuality, in: hubDir))
        }
    }

    @Test("A missing hub directory is a no-op without error")
    func sweepNoOpWhenHubDirectoryMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloaderTests-missing-\(UUID().uuidString)")

        ModelDownloader.sweepOrphanedModels(hubDirectory: missing)

        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Sweep is idempotent across launches")
    func sweepIsIdempotent() throws {
        try withHubDirectory(containing: [Self.retiredFast, Self.retiredBalanced, Self.currentQuality]) { hubDir in
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)

            #expect(!exists(Self.retiredFast, in: hubDir))
            #expect(!exists(Self.retiredBalanced, in: hubDir))
            #expect(exists(Self.currentQuality, in: hubDir))
        }
    }

    @Test("Mixed state: only the allowlisted old dir is removed")
    func sweepMixedState() throws {
        try withHubDirectory(containing: [Self.retiredBalanced, Self.currentQuality]) { hubDir in
            ModelDownloader.sweepOrphanedModels(hubDirectory: hubDir)

            #expect(!exists(Self.retiredBalanced, in: hubDir))
            #expect(exists(Self.currentQuality, in: hubDir))
        }
    }
}

/// Release-gate smoke: each shipped huggingFaceID must actually start downloading
/// through the real ModelDownloader path (HubApi + LLMModelFactory) — a wrong slug
/// would brick users at download time. Off by default (network, multi-GB repos);
/// enable with TEST_RUNNER_LIFEHUG_DOWNLOAD_SMOKE=1 on xcodebuild test. Each test
/// cancels after the first observed bytes, long before the model-init step that
/// would crash on the simulator's missing Metal GPU, then deletes its partial
/// download from the test host's own container.
@Suite(
    "ModelDownloader download smoke",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LIFEHUG_DOWNLOAD_SMOKE"] == "1")
)
@MainActor
struct ModelDownloadSmokeTests {

    private static let selectionKey = "llm_selected_model"

    /// Optional single-tier filter for per-process gate runs (see suite comment).
    /// `nonisolated` — the @Test `arguments:` expression is evaluated outside the
    /// suite's MainActor isolation by the testing macro.
    private nonisolated static let smokeTierFilter = ProcessInfo.processInfo.environment["LIFEHUG_SMOKE_TIER"]

    /// Tiers this process will actually exercise. Driving the parameterization from
    /// the env var (instead of an in-body early return) means a skipped tier emits
    /// NO test case at all — a filtered run can never report skipped-and-passing
    /// cases, so the gate cannot read green without having downloaded something.
    private nonisolated static var smokeTiers: [ModelConfig.LLM.ModelOption] {
        ModelConfig.LLM.ModelOption.allCases.filter {
            smokeTierFilter == nil || $0.rawValue == smokeTierFilter
        }
    }

    @Test("LIFEHUG_SMOKE_TIER names a real tier when set")
    func smokeTierEnvIsValid() {
        if let tier = Self.smokeTierFilter {
            #expect(
                ModelConfig.LLM.ModelOption(rawValue: tier) != nil,
                "LIFEHUG_SMOKE_TIER='\(tier)' matches no tier — set fast|balanced|quality; a typo would otherwise skip every download and read green"
            )
        }
    }

    private func withSavedSelection(_ body: () async throws -> Void) async rethrows {
        let prior = UserDefaults.standard.string(forKey: Self.selectionKey)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: Self.selectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectionKey)
            }
        }
        try await body()
    }

    // A cancelled in-flight download can wedge the shared LLMModelFactory for the
    // rest of the process, so the gate runs one tier per test process: set
    // LIFEHUG_SMOKE_TIER to a tier rawValue and invoke once per tier. The env var
    // drives the `arguments:` list itself, so non-selected tiers produce no cases.
    @Test("Each tier's repo starts downloading real bytes", arguments: smokeTiers)
    func downloadStarts(option: ModelConfig.LLM.ModelOption) async throws {
        try await withSavedSelection {
            ModelConfig.LLM.selectedModel = option
            let downloader = ModelDownloader()
            downloader.startDownload()

            // Wait for the first observed bytes (or a terminal failure). Generous
            // deadline: the reported Progress can stay at 0 for minutes into a
            // multi-GB single-file transfer even while bytes land on disk.
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                if downloader.downloadedMB > 0 || downloader.progress > 0 { break }
                if downloader.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            let observedBytes = downloader.downloadedMB
            let observedProgress = downloader.progress
            downloader.cancelDownload()
            // Let cancellation propagate before removing the partial files.
            try await Task.sleep(for: .seconds(1))
            downloader.deleteCache()

            #expect(
                observedBytes > 0 || observedProgress > 0,
                "\(option.huggingFaceID) never started downloading — \(downloader.errorMessage ?? "no error message")"
            )
        }
    }
}

/// Progress measurement (U1) and completeness/routing (U2). Every seam under
/// test is a pure static that runs on the simulator — no MLX, no network.
@Suite("ModelDownloader progress + completeness")
@MainActor
struct ModelDownloaderProgressTests {

    /// Build a temp model repo directory containing the given relative files,
    /// each `bytesEach` bytes. Runs body, cleans up.
    private func withModelDir(
        files: [String],
        bytesEach: Int = 0,
        _ body: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MDProg-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for rel in files {
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytesEach).write(to: url)
        }
        try body(dir)
    }

    // MARK: - modelDirectoryBytes (U1)

    @Test("Sums all blob bytes, including *.incomplete partials")
    func sumsBytesIncludingIncomplete() throws {
        try withModelDir(files: ["blobs/a", "blobs/b.incomplete"], bytesEach: 1000) { dir in
            #expect(ModelDownloader.modelDirectoryBytes(dir) == 2000)
        }
    }

    @Test("An absent directory sums to zero")
    func absentDirZeroBytes() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDProg-missing-\(UUID().uuidString)")
        #expect(ModelDownloader.modelDirectoryBytes(missing) == 0)
    }

    // MARK: - progressReadout (U1)

    @Test("Maps bytes to MB and fraction against the size estimate")
    func mapsBytesToReadout() {
        let r = ModelDownloader.progressReadout(bytes: 1_299_500_000, diskSizeMB: 2599)
        #expect(abs(r.fraction - 0.5) < 0.001)
        #expect(abs(r.mb - 1299.5) < 0.5)
    }

    @Test("Clamps to 100% when real bytes exceed the size estimate")
    func clampsOverEstimate() {
        let r = ModelDownloader.progressReadout(bytes: 3_000_000_000, diskSizeMB: 2599)
        #expect(r.fraction == 1.0)
        #expect(r.mb == 2599)
    }

    @Test("Readout is non-decreasing in bytes")
    func nonDecreasingInBytes() {
        let lo = ModelDownloader.progressReadout(bytes: 500_000_000, diskSizeMB: 2599)
        let hi = ModelDownloader.progressReadout(bytes: 1_500_000_000, diskSizeMB: 2599)
        #expect(hi.fraction >= lo.fraction)
        #expect(hi.mb >= lo.mb)
    }

    // MARK: - isModelDirComplete (U2)

    @Test("A directory with no *.incomplete reports complete")
    func completeDirNoIncomplete() throws {
        try withModelDir(files: ["blobs/weights", "config.json"], bytesEach: 10) { dir in
            #expect(ModelDownloader.isModelDirComplete(dir) == true)
        }
    }

    @Test("A directory with a *.incomplete blob reports incomplete")
    func partialDirIncomplete() throws {
        try withModelDir(files: ["blobs/weights.incomplete"], bytesEach: 10) { dir in
            #expect(ModelDownloader.isModelDirComplete(dir) == false)
        }
    }

    @Test("A nested *.incomplete anywhere beneath is detected")
    func nestedIncompleteDetected() throws {
        try withModelDir(files: ["blobs/sub/x.incomplete", "config.json"], bytesEach: 10) { dir in
            #expect(ModelDownloader.isModelDirComplete(dir) == false)
        }
    }

    // MARK: - launchRoute (U2)

    @Test("A complete cache routes to load")
    func routeLoadCached() {
        #expect(ModelDownloader.launchRoute(cached: .quality, incomplete: nil) == .loadCached(.quality))
    }

    @Test("A partial-only state routes to resume-download")
    func routeResume() {
        #expect(ModelDownloader.launchRoute(cached: nil, incomplete: .quality) == .resumeDownload(.quality))
    }

    @Test("Nothing on disk routes to the picker")
    func routePicker() {
        #expect(ModelDownloader.launchRoute(cached: nil, incomplete: nil) == .showPicker)
    }
}

/// Cellular download gate (U3). The NWPathMonitor wrapper is device-tested; here
/// the pure decision and its application are covered without a live connection.
@Suite("ModelState download gate")
@MainActor
struct ModelStateGateTests {

    @Test("A non-expensive path proceeds")
    func gateProceeds() {
        #expect(ModelState.downloadGate(isExpensive: false, sizeMB: 2599) == .proceed)
    }

    @Test("An expensive path defers to a cellular confirmation")
    func gateConfirms() {
        #expect(ModelState.downloadGate(isExpensive: true, sizeMB: 2599) == .confirmCellular(sizeMB: 2599))
    }

    @Test("Applying the cellular gate sets the confirm flag and starts no download")
    func applyConfirmSetsFlag() {
        let state = ModelState()
        state.applyDownloadGate(.confirmCellular(sizeMB: 2599))
        #expect(state.pendingCellularConfirm == true)
        if case .downloading = state.status {
            Issue.record("cellular confirmation must not start the download")
        }
    }
}
