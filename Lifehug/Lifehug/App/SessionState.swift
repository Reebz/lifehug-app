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

    // MARK: - Conversation Management

    func addTurn(role: ConversationTurn.Role, text: String) {
        let turn = ConversationTurn(role: role, text: text, timestamp: Date())
        conversationTurns.append(turn)
        autoSave()
    }

    /// Compile all user turns into a single coherent answer text.
    func compileAnswer() -> String {
        let userTurns = conversationTurns.filter { $0.role == .user }
        return userTurns.map(\.text).joined(separator: "\n\n")
    }

    /// Reset session state for a new question.
    func resetSession() {
        currentQuestion = nil
        conversationTurns = []
        isRecording = false
        draftTranscript = ""
        clearAutoSave()
    }

    // MARK: - Auto-Save

    private static let autoSaveKey = "sessionAutoSave"

    func autoSave() {
        guard currentQuestion != nil, !conversationTurns.isEmpty else { return }
        let saveable = conversationTurns.map { SaveableTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text, timestamp: $0.timestamp) }
        let payload = AutoSavePayload(
            questionID: currentQuestion?.id,
            questionText: currentQuestion?.text,
            questionCategory: currentQuestion.map { String($0.category) },
            turns: saveable
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.autoSaveKey)
        }
    }

    func restoreAutoSave() {
        guard let data = UserDefaults.standard.data(forKey: Self.autoSaveKey),
              let payload = try? JSONDecoder().decode(AutoSavePayload.self, from: data) else { return }

        conversationTurns = payload.turns.map {
            ConversationTurn(role: $0.role == "user" ? .user : .assistant, text: $0.text, timestamp: $0.timestamp)
        }

        // Restore question context if available
        if let id = payload.questionID, let text = payload.questionText {
            let category = payload.questionCategory?.first ?? "A"
            currentQuestion = Question(id: id, category: category, text: text, answered: false)
        }

        logger.info("Restored \(self.conversationTurns.count) conversation turns from auto-save")
    }

    private func clearAutoSave() {
        UserDefaults.standard.removeObject(forKey: Self.autoSaveKey)
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
