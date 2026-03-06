import SwiftUI

@Observable
@MainActor
final class SessionState {
    var currentQuestion: Question?
    var conversationTurns: [ConversationTurn] = []
    var isRecording: Bool = false
    var draftTranscript: String = ""

    // MARK: - Conversation Management

    func addTurn(role: ConversationTurn.Role, text: String) {
        let turn = ConversationTurn(role: role, text: text, timestamp: Date())
        conversationTurns.append(turn)
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
