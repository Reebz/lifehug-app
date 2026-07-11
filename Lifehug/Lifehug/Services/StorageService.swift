import Foundation
import os

final class StorageService {
    private let logger = Logger(subsystem: "com.lifehug.app", category: "Storage")
    private let fileManager = FileManager.default

    // MARK: - iCloud Backup Preference

    private static let iCloudBackupKey = "iCloudBackupEnabled"

    static var iCloudBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: iCloudBackupKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: iCloudBackupKey) }
    }

    // MARK: - Silence Timeout Preference

    private static let silenceTimeoutKey = "silenceTimeoutSeconds"

    static var silenceTimeout: TimeInterval {
        get {
            // Distinguish "never set" (nil → default 3.0) from "explicitly set to 0" (Off)
            guard let stored = UserDefaults.standard.object(forKey: silenceTimeoutKey) as? Double else {
                return 3.0
            }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: silenceTimeoutKey) }
    }

    // MARK: - Directory Paths

    /// Application Support — models and state (not visible in Files app)
    var appSupportDirectory: URL {
        guard let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable — iOS sandbox is broken")
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Documents — user content (visible in Files app)
    var documentsDirectory: URL {
        guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — iOS sandbox is broken")
        }
        return url
    }

    var modelsDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("models", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var stateDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("system", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var answersDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("answers", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Committed per-turn voice clips (`.m4a`), one answer's clips keyed by filename.
    /// The answer record is the index over these; deleting audio deletes clips here.
    var clipsDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("clips", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Per-recording-session staging area (subdirectory per recording UUID, KTD7).
    /// Clips are written here during a session and moved into `clipsDirectory` only
    /// when the answer save succeeds; abandoned subdirectories are swept by launch
    /// reconciliation (U7).
    var clipsStagingDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("clips-staging", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var questionBankURL: URL {
        documentsDirectory.appendingPathComponent("question-bank.md")
    }

    var rotationURL: URL {
        stateDirectory.appendingPathComponent("rotation.json")
    }

    var configURL: URL {
        documentsDirectory.appendingPathComponent("config.json")
    }

    // MARK: - Setup

    func setupDirectories() throws {
        // Create directories
        let dirs = [modelsDirectory, stateDirectory, answersDirectory, clipsDirectory, clipsStagingDirectory]
        for dir in dirs {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // NSFileProtectionComplete on user data directories
        let protectedPaths = [
            answersDirectory.path,
            questionBankURL.deletingLastPathComponent().path,
            configURL.deletingLastPathComponent().path,
            stateDirectory.path,
        ]
        for path in protectedPaths {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: path
            )
        }

        // Clips use the relaxed `.completeUnlessOpen` class (KTD4): a clip being written
        // when the device locks must be allowed to finish. `.complete` (above) would fail
        // that in-progress write. New files inherit the directory's class, so the staging
        // area where the live teardown write lands gets it too; per-clip writes re-assert
        // it via `durablePlace`.
        for path in [clipsDirectory.path, clipsStagingDirectory.path] {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: path
            )
        }

        // Always exclude models from iCloud backup (large binary files)
        var modelsURL = modelsDirectory
        var modelsResourceValues = URLResourceValues()
        modelsResourceValues.isExcludedFromBackup = true
        try modelsURL.setResourceValues(modelsResourceValues)

        // Exclude user data from iCloud backup if user has disabled it. Clips are user
        // data (irreplaceable recordings) and follow the same setting (KTD5), unlike
        // models which are always excluded because they are re-downloadable.
        if !Self.iCloudBackupEnabled {
            let userDataDirs = [answersDirectory, stateDirectory, clipsDirectory, clipsStagingDirectory, documentsDirectory]
            for var dirURL in userDataDirs {
                var rv = URLResourceValues()
                rv.isExcludedFromBackup = true
                try dirURL.setResourceValues(rv)
            }
        }

        logger.info("Storage directories configured")
    }

    // MARK: - First Launch

    func copyBundledQuestionBankIfNeeded() throws {
        guard !fileManager.fileExists(atPath: questionBankURL.path) else { return }
        guard let bundledURL = Bundle.main.url(forResource: "question-bank", withExtension: "md") else {
            logger.error("Bundled question-bank.md not found")
            return
        }
        try fileManager.copyItem(at: bundledURL, to: questionBankURL)
        logger.info("Copied bundled question-bank.md to Documents")
    }

    // MARK: - Question Bank I/O

    func readQuestionBank() throws -> String {
        try String(contentsOf: questionBankURL, encoding: .utf8)
    }

    func writeQuestionBank(_ content: String) throws {
        try atomicWrite(content: content, to: questionBankURL)
    }

    // MARK: - Rotation State I/O

    func readRotationState() -> RotationState {
        guard fileManager.fileExists(atPath: rotationURL.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: rotationURL)
            return try JSONDecoder().decode(RotationState.self, from: data)
        } catch {
            logger.warning("Rotation state read failed, using defaults: \(error)")
            return .default
        }
    }

    func writeRotationState(_ state: RotationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try atomicWrite(data: data, to: rotationURL)
    }

    // MARK: - Config I/O

    func readConfig() -> UserConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return UserConfig()
        }
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(UserConfig.self, from: data)
        } catch {
            logger.warning("Config read failed, using defaults: \(error)")
            return UserConfig()
        }
    }

    func writeConfig(_ config: UserConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try atomicWrite(data: data, to: configURL)
    }

    // MARK: - Answer File I/O

    func saveAnswer(_ answer: Answer) throws {
        // Defense-in-depth: validate questionID format before constructing file path.
        // IDs are generated internally (e.g., "A1", "K12") but this guard prevents
        // path traversal if a malformed ID ever reaches this code path.
        guard answer.questionID.range(of: #"^[A-Z]\d+$"#, options: .regularExpression) != nil else {
            logger.error("Invalid questionID format: \(answer.questionID)")
            return
        }
        let filename = "\(answer.questionID).md"
        let url = answersDirectory.appendingPathComponent(filename)
        let content = answer.toMarkdown()
        try atomicWrite(content: content, to: url)
        logger.info("Saved answer for \(answer.questionID)")
    }

    /// Validated URL for an answer's markdown file. Mirrors `saveAnswer`'s regex guard but
    /// throws so callers (re-transcription, deletion) fail loudly on a malformed id.
    func answerURL(questionID: String) throws -> URL {
        guard questionID.range(of: #"^[A-Z]\d+$"#, options: .regularExpression) != nil else {
            throw StorageError.invalidAnswerID(questionID)
        }
        return answersDirectory.appendingPathComponent("\(questionID).md")
    }

    func listAnswerFiles() throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: answersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func readAnswer(at url: URL) throws -> Answer? {
        let content = try String(contentsOf: url, encoding: .utf8)
        return Answer.fromMarkdown(content)
    }

    /// Commit an answer's staged clips, THEN save the answer referencing only the clips that
    /// actually committed. Commit-first (not save-first) so a save failure leaves committed
    /// clips as safe, reported orphans (R7) rather than a durable answer referencing audio a
    /// later reconciliation would strip — the "never lose audio" guarantee wins over KTD7's
    /// literal ordering. A clip whose encode + raw-recovery both failed becomes clip-less
    /// (its segment keeps whatever text it had). Returns the final saved answer.
    @discardableResult
    func saveAnswerCommittingClips(_ answer: Answer, recordingSessionID: String) throws -> Answer {
        let committed = Set(commitClips(recordingSessionID: recordingSessionID))
        let reconciled = answer.segments.map { seg -> Answer.Segment in
            guard let clip = seg.clipFilename, !committed.contains(clip) else { return seg }
            var cleared = seg
            cleared.clipFilename = nil
            return cleared
        }
        let final = reconciled == answer.segments ? answer : answer.replacingSegments(reconciled)
        try saveAnswer(final)
        return final
    }

    // MARK: - Answer / Audio Deletion (U7)

    /// Delete an answer entirely: its markdown file and its committed clips (R6). The app's
    /// first destructive answer operation — callers confirm first. Chapter provenance sourced
    /// from these clips is pruned by `pruneProvenance(forDeletedClips:)` (U10).
    func deleteAnswer(_ answer: Answer) throws {
        for clip in answer.segments.compactMap(\.clipFilename) {
            try? AudioClipStore.deleteClip(at: clipsDirectory.appendingPathComponent(clip))
        }
        // Prune by answer id so links from this answer's TEXT segments (no clip) are dropped
        // too, not just its audio links.
        pruneProvenanceSidecars(deletedAnswerID: answer.questionID)
        let url = try answerURL(questionID: answer.questionID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Delete only an answer's audio: remove its clips and clear the clip references on its
    /// segments, leaving the text answer intact (R6/AE5). Returns the updated answer.
    @discardableResult
    func deleteAudio(for answer: Answer) throws -> Answer {
        let removedClips = answer.segments.compactMap(\.clipFilename)
        for clip in removedClips {
            try? AudioClipStore.deleteClip(at: clipsDirectory.appendingPathComponent(clip))
        }
        let cleared = answer.segments.map { seg -> Answer.Segment in
            var s = seg
            s.clipFilename = nil
            return s
        }
        let updated = answer.replacingSegments(cleared)
        try saveAnswer(updated)
        pruneProvenance(forDeletedClips: removedClips)
        return updated
    }

    /// Delete a prior answer's clips that the new answer no longer references (re-answer
    /// contract, KTD9). Called as one explicit step after the new answer save succeeds.
    func deletePriorClips(_ priorClips: [String], keeping newClips: Set<String>) {
        for clip in priorClips where !newClips.contains(clip) {
            try? AudioClipStore.deleteClip(at: clipsDirectory.appendingPathComponent(clip))
        }
        pruneProvenance(forDeletedClips: priorClips.filter { !newClips.contains($0) })
    }

    /// Prune chapter provenance (sidecar links + pull-quotes) whose source clips were deleted
    /// (U7 + KTD13). The full sidecar-pruning body is added in U10; until then this is a safe
    /// no-op, so deletion works before Phase B lands.
    func pruneProvenance(forDeletedClips clips: [String]) {
        guard !clips.isEmpty else { return }
        pruneProvenanceSidecars(deletedClips: Set(clips))
    }

    /// Remove sidecar links (and their pull-quotes) whose source clip was deleted, or whose
    /// whole source answer was deleted (U7/KTD13), across every chapter provenance sidecar.
    /// Pruning by answer id also drops links from deleted TEXT segments, which have no clip.
    /// No-op when nothing is targeted or no sidecars exist.
    func pruneProvenanceSidecars(deletedClips: Set<String> = [], deletedAnswerID: String? = nil) {
        guard !deletedClips.isEmpty || deletedAnswerID != nil,
              let files = try? fileManager.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasSuffix(".provenance.json") {
            guard let data = try? Data(contentsOf: url),
                  var provenance = try? JSONDecoder().decode(ChapterProvenance.self, from: data) else { continue }
            var changed = false
            for i in provenance.passages.indices {
                let before = provenance.passages[i].links.count
                provenance.passages[i].links.removeAll { link in
                    (link.clipFilename.map { deletedClips.contains($0) } ?? false)
                        || (deletedAnswerID != nil && link.questionID == deletedAnswerID)
                }
                if provenance.passages[i].links.count != before { changed = true }
            }
            if changed { try? saveProvenance(provenance) }
        }
    }

    // MARK: - Draft I/O

    var draftsDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("drafts", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func saveDraft(categoryLetter: Character, content: String) throws {
        let filename = "chapter-\(categoryLetter).md"
        let url = draftsDirectory.appendingPathComponent(filename)
        try atomicWrite(content: content, to: url)
        logger.info("Saved draft for category \(String(categoryLetter))")
    }

    func readDraft(categoryLetter: Character) throws -> String? {
        let filename = "chapter-\(categoryLetter).md"
        let url = draftsDirectory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Provenance Sidecar (U10 / KTD13)

    func provenanceURL(categoryLetter: Character) -> URL {
        draftsDirectory.appendingPathComponent("chapter-\(categoryLetter).provenance.json")
    }

    /// Persist a chapter's provenance sidecar (KTD13/KTD16): durable write, the clips'
    /// protection class, and user-gated backup exclusion (it carries verbatim speech). Throws
    /// so a failed provenance write surfaces rather than silently dropping.
    func saveProvenance(_ provenance: ChapterProvenance) throws {
        guard let letter = provenance.categoryLetter.first else {
            throw StorageError.invalidAnswerID(provenance.categoryLetter)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(provenance)
        try durableWrite(
            data,
            to: provenanceURL(categoryLetter: letter),
            protection: .completeUnlessOpen,
            excludeFromBackup: !Self.iCloudBackupEnabled
        )
    }

    /// Lenient read — a corrupt/absent sidecar returns nil, mirroring the app's read-path
    /// convention (the sidecar is regenerable).
    func readProvenance(categoryLetter: Character) -> ChapterProvenance? {
        let url = provenanceURL(categoryLetter: categoryLetter)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChapterProvenance.self, from: data)
    }

    // MARK: - Chapter Consent Record (U11 / KTD15)

    func chapterRecordURL(categoryLetter: Character) -> URL {
        draftsDirectory.appendingPathComponent("chapter-\(categoryLetter).consent.json")
    }

    /// Persist a chapter's consent record durably (KTD16). Throws so a failed write surfaces.
    func saveChapterRecord(_ record: ChapterRecord) throws {
        guard let letter = record.categoryLetter.first else {
            throw StorageError.invalidAnswerID(record.categoryLetter)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try durableWrite(
            data,
            to: chapterRecordURL(categoryLetter: letter),
            protection: .complete,
            excludeFromBackup: !Self.iCloudBackupEnabled
        )
    }

    /// Lenient read — a corrupt/absent record returns nil (an interim draft has none, R15).
    func readChapterRecord(categoryLetter: Character) -> ChapterRecord? {
        let url = chapterRecordURL(categoryLetter: categoryLetter)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChapterRecord.self, from: data)
    }

    // MARK: - Clip Filenames

    /// Clip filenames are `<questionID>-<recordingUUID>-<turnIndex>.m4a` (KTD7). This is
    /// the path-safety guard, mirroring `saveAnswer`'s regex but throwing (KTD16): a
    /// clip is unrecoverable, so a malformed key must never silently no-op.
    nonisolated static func isValidClipFilename(_ name: String) -> Bool {
        name.range(
            of: #"^[A-Z]\d+-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-\d+\.m4a$"#,
            options: .regularExpression
        ) != nil
    }

    /// Validated URL for a committed clip. Throws `invalidClipKey` on a malformed name.
    func clipURL(filename: String) throws -> URL {
        guard Self.isValidClipFilename(filename) else {
            throw StorageError.invalidClipKey(filename)
        }
        return clipsDirectory.appendingPathComponent(filename)
    }

    /// Move a recording session's staged clips into the committed clips directory. Called
    /// only after the answer save succeeds, so a clip becomes committed exactly when its
    /// answer is durable (KTD7). Ignores non-clip staging artifacts (raw dumps, encode
    /// temps); leaves the staging subdirectory for reconciliation if any remain. Returns the
    /// committed filenames.
    @discardableResult
    func commitClips(recordingSessionID: String) -> [String] {
        let stagingDir = clipsStagingDirectory.appendingPathComponent(recordingSessionID, isDirectory: true)
        guard fileManager.fileExists(atPath: stagingDir.path),
              let entries = try? fileManager.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
        else { return [] }

        // Recover any raw dump whose off-path AAC encode never produced its `.m4a` (the raw
        // dump is the durability point — KTD2 — so it MUST be recoverable, not discarded).
        // Raw files are named `<clip>.raw` where `<clip>` is the target `.m4a` filename.
        for raw in entries where raw.pathExtension == "raw" {
            let clipName = raw.deletingPathExtension().lastPathComponent
            guard Self.isValidClipFilename(clipName) else { continue }
            let m4a = stagingDir.appendingPathComponent(clipName)
            if !fileManager.fileExists(atPath: m4a.path),
               let samples = try? AudioClipStore.readRawDump(at: raw),
               (try? AudioClipStore.encode(samples: samples, to: m4a)) != nil {
                try? AudioClipStore.deleteClip(at: raw)  // recovered → raw no longer needed
            }
        }

        // Commit every valid `.m4a` — best-effort per clip so one durable-place failure never
        // aborts the rest and never throws (a throw would strand the others in staging).
        var committed: [String] = []
        let refreshed = (try? fileManager.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)) ?? []
        for src in refreshed where Self.isValidClipFilename(src.lastPathComponent) {
            guard let dest = try? clipURL(filename: src.lastPathComponent) else { continue }
            do {
                try durablePlace(tempFile: src, at: dest, protection: .completeUnlessOpen, excludeFromBackup: !Self.iCloudBackupEnabled)
                committed.append(src.lastPathComponent)
            } catch {
                logger.error("Clip commit failed for \(src.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }

        // Drop the staging subdir only when fully drained; anything left is swept by launch
        // reconciliation.
        if let remaining = try? fileManager.contentsOfDirectory(atPath: stagingDir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: stagingDir)
        }
        return committed
    }

    // MARK: - Clip Reconciliation (U7)

    /// Snapshot of clip-storage health for the settings view (U8). Orphaned clips are real,
    /// well-formed committed clips that no answer references — reported, never auto-deleted.
    struct ClipReconciliationReport: Equatable {
        var missingClipReferences = 0
        var orphanedClips = 0
        var orphanedBytes: Int64 = 0
    }

    /// Launch reconciliation (U7/R7): remove crash fragments and abandoned staging, repair
    /// answers that reference a now-missing clip (segment goes clip-less), and report — never
    /// auto-delete — committed clips that no answer references. Idempotent. Never removes a
    /// well-formed committed clip. `protectedSession` (the current/restored recording session)
    /// is spared so an in-progress session's staged clips survive.
    @discardableResult
    func reconcileClipStorage(protectingStagingSession protectedSession: String? = nil) -> ClipReconciliationReport {
        let fm = fileManager

        // 1. Remove fragments (invalid name or zero bytes) from the committed clips dir.
        if let entries = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in entries {
                let name = url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if !Self.isValidClipFilename(name) || size == 0 {
                    try? fm.removeItem(at: url)
                }
            }
        }

        // 2. Remove abandoned staging subdirectories (all but the protected session's).
        if let stagingEntries = try? fm.contentsOfDirectory(at: clipsStagingDirectory, includingPropertiesForKeys: nil) {
            for entry in stagingEntries where entry.lastPathComponent != protectedSession {
                try? fm.removeItem(at: entry)
            }
        }

        // 3. Repair answers referencing a missing clip: the segment goes clip-less (its audio
        //    is gone) but keeps whatever text it had. Also collect the referenced clip set.
        let answers = (try? listAnswerFiles())?.compactMap { try? readAnswer(at: $0) } ?? []
        var referenced = Set<String>()
        var missingClips = Set<String>()
        var missingRefs = 0
        for answer in answers {
            var segs = answer.segments
            var changed = false
            for i in segs.indices {
                guard let clip = segs[i].clipFilename else { continue }
                if fm.fileExists(atPath: clipsDirectory.appendingPathComponent(clip).path) {
                    referenced.insert(clip)
                } else {
                    segs[i].clipFilename = nil
                    missingClips.insert(clip)
                    changed = true
                    missingRefs += 1
                }
            }
            if changed {
                try? saveAnswer(answer.replacingSegments(segs))
            }
        }
        // Prune provenance links that pointed at a now-vanished clip.
        pruneProvenanceSidecars(deletedClips: missingClips)

        // 4. Orphaned committed clips: valid clips no answer references — reported only (R7).
        var orphanCount = 0
        var orphanBytes: Int64 = 0
        if let entries = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in entries where Self.isValidClipFilename(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
                orphanCount += 1
                orphanBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        return ClipReconciliationReport(
            missingClipReferences: missingRefs,
            orphanedClips: orphanCount,
            orphanedBytes: orphanBytes
        )
    }

    /// Read-only clip-storage report for the settings view (U8) — orphan count/size without
    /// mutating anything (no fragment/staging cleanup, no answer repair).
    func clipStorageReport() -> ClipReconciliationReport {
        let fm = fileManager
        let answers = (try? listAnswerFiles())?.compactMap { try? readAnswer(at: $0) } ?? []
        let referenced = Set(answers.flatMap { $0.segments.compactMap(\.clipFilename) })
        var orphanCount = 0
        var orphanBytes: Int64 = 0
        if let entries = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in entries where Self.isValidClipFilename(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
                orphanCount += 1
                orphanBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ClipReconciliationReport(missingClipReferences: 0, orphanedClips: orphanCount, orphanedBytes: orphanBytes)
    }

    // MARK: - Durable Write (crash-safe: staged temp + F_FULLFSYNC + atomic rename)

    /// Crash-safe write of `data` to `url`: stage in a sibling temp file, force the bytes
    /// to stable storage (`F_FULLFSYNC`), atomically rename into place, then fsync the
    /// containing directory so the rename itself survives power loss. Protection class and
    /// backup exclusion are set per-file at write time (KTD3) — the launch-time
    /// `setupDirectories()` pass does not cover files created later. Used for provenance
    /// sidecars, the retry queue, and consent records.
    func durableWrite(
        _ data: Data,
        to url: URL,
        protection: FileProtectionType,
        excludeFromBackup: Bool
    ) throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".durable-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: Self.writingOption(for: protection))
            try Self.fullFsync(at: temp)
            try commitTemp(temp, to: url)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
        try applyFileFlags(to: url, protection: protection, excludeFromBackup: excludeFromBackup)
        Self.fullFsyncDirectory(dir)
    }

    /// Durably place an already-written temp file (e.g. an encoded `.m4a`) at `url`:
    /// fsync the temp, atomically rename into place, set protection + backup flags, then
    /// fsync the directory. The caller owns producing `tempFile`; on success it no longer
    /// exists (it was renamed). Used for clips (KTD2/KTD3).
    func durablePlace(
        tempFile: URL,
        at url: URL,
        protection: FileProtectionType,
        excludeFromBackup: Bool
    ) throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.fullFsync(at: tempFile)
        try commitTemp(tempFile, to: url)
        try applyFileFlags(to: url, protection: protection, excludeFromBackup: excludeFromBackup)
        Self.fullFsyncDirectory(dir)
    }

    /// Atomic rename of `temp` onto `url`: `replaceItemAt` when a file already exists
    /// there (no window where the old content is partially visible), `moveItem` otherwise.
    private func commitTemp(_ temp: URL, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    private func applyFileFlags(
        to url: URL,
        protection: FileProtectionType,
        excludeFromBackup: Bool
    ) throws {
        try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = excludeFromBackup
        try u.setResourceValues(rv)
    }

    private static func writingOption(for protection: FileProtectionType) -> Data.WritingOptions {
        switch protection {
        case .completeUnlessOpen: return [.completeFileProtectionUnlessOpen]
        case .completeUntilFirstUserAuthentication: return [.completeFileProtectionUntilFirstUserAuthentication]
        case .none: return [.noFileProtection]
        default: return [.completeFileProtection]
        }
    }

    /// Force a file's bytes to stable storage. Plain `fsync` only pushes to the drive
    /// cache; `F_FULLFSYNC` waits for the platter/flash, the guarantee this feature needs.
    private static func fullFsync(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            throw StorageError.fsyncFailed(url.lastPathComponent)
        }
    }

    /// Best-effort directory fsync so a completed rename survives power loss. Directory
    /// durability is belt-and-suspenders; a failure here is not fatal to the write.
    private static func fullFsyncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    // MARK: - Atomic Write

    private func atomicWrite(content: String, to url: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw StorageError.encodingFailed
        }
        try atomicWrite(data: data, to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

enum StorageError: Error {
    case encodingFailed
    case fileNotFound(String)
    case invalidClipKey(String)
    case invalidAnswerID(String)
    case fsyncFailed(String)
}
