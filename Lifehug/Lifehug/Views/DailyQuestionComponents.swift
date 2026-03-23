import SwiftUI

// MARK: - Leaf Views (Performance-Critical)
// These take explicit parameters — NOT @Environment — so SwiftUI only
// recomputes them when their specific inputs change. This avoids
// per-token recomputation of the entire ~800-line parent view.

/// Displays the live streaming LLM response text.
struct StreamingResponseBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("AI:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.sageGreen)
            Text(text)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmCharcoal.opacity(0.8))
        }
        .padding(.horizontal, 16)
    }
}

/// Displays the live partial transcript while the user is speaking.
struct LiveTranscriptBubble: View {
    let transcript: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("You:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.terracotta)
            Text(transcript)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmCharcoal.opacity(0.6))
                .italic()
        }
        .padding(.horizontal, 16)
    }
}

/// Displays a single conversation turn bubble (user or AI).
struct VoiceTranscriptBubble: View {
    let role: ConversationTurn.Role
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(role == .user ? "You:" : "AI:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(role == .user ? Theme.terracotta : Theme.sageGreen)
            Text(text)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
        .padding(.horizontal, 16)
    }
}
