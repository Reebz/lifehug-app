import SwiftUI
import os

@Observable
@MainActor
final class SessionState {
    var currentQuestion: Question?
    var conversationTurns: [ConversationTurn] = []
    var isRecording: Bool = false
    var draftTranscript: String = ""

    /// Identifies this answer's recording session (KTD7). Keys the clip staging subdirectory
    /// and is embedded in every clip filename, so it must survive a kill + restore or the
    /// staged clips would be orphaned. A fresh id is minted per answer in `resetSession`.
    private(set) var recordingSessionID = UUID()

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Session")
    private let fileManager = FileManager.default

    /// Debounce task for auto-save writes.
    private var autoSaveTask: Task<Void, Never>?

    // MARK: - Conversation Management

    func addTurn(
        role: ConversationTurn.Role,
        text: String,
        clipFilename: String? = nil,
        isVoice: Bool = false,
        needsTranscription: Bool = false
    ) {
        let turn = ConversationTurn(
            role: role,
            text: text,
            timestamp: Date(),
            clipFilename: clipFilename,
            isVoice: isVoice,
            needsTranscription: needsTranscription
        )
        conversationTurns.append(turn)
        scheduleAutoSave()
    }

    /// Compile all user turns into a single coherent answer text.
    func compileAnswer() -> String {
        let userTurns = conversationTurns.filter { $0.role == .user }
        return userTurns.map(\.text).joined(separator: "\n\n")
    }

    /// Build the ordered segment list from user turns (KTD6). Segment order matches
    /// `compileAnswer()` and the per-turn clip filenames' turn indices.
    func compileSegments() -> [Answer.Segment] {
        conversationTurns
            .filter { $0.role == .user }
            .map { turn in
                Answer.Segment(
                    text: turn.text,
                    clipFilename: turn.clipFilename,
                    source: turn.isVoice ? .voice : .text,
                    isEdited: false,
                    needsTranscription: turn.needsTranscription
                )
            }
    }

    /// Flush any pending auto-save immediately (no debounce).
    /// Call when the app is about to enter background.
    func flushAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSave()
    }

    /// Reset session state for a new question.
    func resetSession() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        currentQuestion = nil
        conversationTurns = []
        isRecording = false
        draftTranscript = ""
        // Mint a fresh recording session so the next answer's clips get their own staging
        // subdirectory and never collide with the answer just finished.
        recordingSessionID = UUID()
        clearAutoSave()
    }

    // MARK: - Auto-Save (encrypted file storage)

    /// Legacy UserDefaults key — used only for one-time migration.
    private static let legacyAutoSaveKey = "sessionAutoSave"

    private var autoSaveFileURL: URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable — iOS sandbox is broken")
        }
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("autosave.json")
    }

    /// Debounced auto-save: cancels any pending save and schedules a new one after 2 seconds.
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            autoSave()
        }
    }

    /// Write session state to an encrypted file immediately.
    func autoSave() {
        guard currentQuestion != nil, !conversationTurns.isEmpty else { return }
        let saveable = conversationTurns.map {
            SaveableTurn(
                role: $0.role == .user ? "user" : "assistant",
                text: $0.text,
                timestamp: $0.timestamp,
                clipFilename: $0.clipFilename,
                isVoice: $0.isVoice,
                needsTranscription: $0.needsTranscription
            )
        }
        let payload = AutoSavePayload(
            questionID: currentQuestion?.id,
            questionText: currentQuestion?.text,
            questionCategory: currentQuestion.map { String($0.category) },
            turns: saveable,
            recordingSessionID: recordingSessionID.uuidString
        )
        do {
            let data = try JSONEncoder().encode(payload)
            let url = autoSaveFileURL
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            var resourceURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try resourceURL.setResourceValues(resourceValues)
        } catch {
            logger.error("Auto-save failed: \(error.localizedDescription)")
        }
    }

    func restoreAutoSave() {
        migrateAutoSaveFromUserDefaultsIfNeeded()

        let url = autoSaveFileURL
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(AutoSavePayload.self, from: data)
            conversationTurns = payload.turns.map {
                ConversationTurn(
                    role: $0.role == "user" ? .user : .assistant,
                    text: $0.text,
                    timestamp: $0.timestamp,
                    clipFilename: $0.clipFilename,
                    isVoice: $0.isVoice ?? false,
                    needsTranscription: $0.needsTranscription ?? false
                )
            }
            // Restore the recording session id so already-staged clips stay linked to the
            // restored turns (KTD7). Absent in pre-feature payloads → keep the fresh id.
            if let restored = payload.recordingSessionID, let uuid = UUID(uuidString: restored) {
                recordingSessionID = uuid
            }

            // Restore question context if available
            if let id = payload.questionID, let text = payload.questionText {
                let category = payload.questionCategory?.first ?? "A"
                currentQuestion = Question(id: id, category: category, text: text, answered: false)
            }

            logger.info("Restored \(self.conversationTurns.count) conversation turns from auto-save")
        } catch {
            logger.error("Failed to restore auto-save: \(error.localizedDescription)")
        }
    }

    private func clearAutoSave() {
        let url = autoSaveFileURL
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            logger.error("Failed to clear auto-save file: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration from UserDefaults

    /// One-time migration: move auto-save data from UserDefaults to encrypted file.
    private func migrateAutoSaveFromUserDefaultsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyAutoSaveKey) else { return }
        do {
            let url = autoSaveFileURL
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            var resourceURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try resourceURL.setResourceValues(resourceValues)
            UserDefaults.standard.removeObject(forKey: Self.legacyAutoSaveKey)
            logger.info("Migrated auto-save data from UserDefaults to encrypted file")
        } catch {
            logger.error("Auto-save migration failed: \(error.localizedDescription)")
        }
    }

    private struct SaveableTurn: Codable {
        let role: String
        let text: String
        let timestamp: Date
        // Optional so pre-feature payloads (missing these keys) still decode (KTD7).
        var clipFilename: String? = nil
        var isVoice: Bool? = nil
        var needsTranscription: Bool? = nil
    }

    private struct AutoSavePayload: Codable {
        let questionID: String?
        let questionText: String?
        let questionCategory: String?
        let turns: [SaveableTurn]
        var recordingSessionID: String? = nil
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
    /// Committed/staged clip filename for a voice turn (KTD7); nil for typed turns and
    /// capture failures. The in-memory `id` above is regenerated on restore and must never
    /// key anything persistent — the clip reference is what survives a kill + restore.
    var clipFilename: String? = nil
    var isVoice: Bool = false
    /// Audio was kept but the transcript came back empty/failed — recoverable later (R3).
    var needsTranscription: Bool = false

    enum Role {
        case user
        case assistant
    }
}
