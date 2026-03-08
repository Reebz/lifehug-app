import SwiftUI
import os

@Observable
@MainActor
final class SessionState {
    var currentQuestion: Question?
    var conversationTurns: [ConversationTurn] = []
    var isRecording: Bool = false
    var draftTranscript: String = ""

    private let logger = Logger(subsystem: "com.lifehug.app", category: "Session")
    private let fileManager = FileManager.default

    /// Debounce task for auto-save writes.
    private var autoSaveTask: Task<Void, Never>?

    // MARK: - Conversation Management

    func addTurn(role: ConversationTurn.Role, text: String) {
        let turn = ConversationTurn(role: role, text: text, timestamp: Date())
        conversationTurns.append(turn)
        scheduleAutoSave()
    }

    /// Compile all user turns into a single coherent answer text.
    func compileAnswer() -> String {
        let userTurns = conversationTurns.filter { $0.role == .user }
        return userTurns.map(\.text).joined(separator: "\n\n")
    }

    /// Reset session state for a new question.
    func resetSession() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        currentQuestion = nil
        conversationTurns = []
        isRecording = false
        draftTranscript = ""
        clearAutoSave()
    }

    // MARK: - Auto-Save (encrypted file storage)

    /// Legacy UserDefaults key — used only for one-time migration.
    private static let legacyAutoSaveKey = "sessionAutoSave"

    private var autoSaveFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        let saveable = conversationTurns.map { SaveableTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text, timestamp: $0.timestamp) }
        let payload = AutoSavePayload(
            questionID: currentQuestion?.id,
            questionText: currentQuestion?.text,
            questionCategory: currentQuestion.map { String($0.category) },
            turns: saveable
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
                ConversationTurn(role: $0.role == "user" ? .user : .assistant, text: $0.text, timestamp: $0.timestamp)
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
    }

    private struct AutoSavePayload: Codable {
        let questionID: String?
        let questionText: String?
        let questionCategory: String?
        let turns: [SaveableTurn]
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }
}
