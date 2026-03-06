import SwiftUI

@Observable
@MainActor
final class SessionState {
    var currentQuestion: Question?
    var conversationTurns: [ConversationTurn] = []
    var isRecording: Bool = false
    var draftTranscript: String = ""
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
