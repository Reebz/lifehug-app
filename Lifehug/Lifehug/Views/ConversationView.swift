import SwiftUI

struct ConversationView: View {
    @Environment(SessionState.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Binding var questions: [Question]
    @Binding var categories: [Character: Category]
    @Binding var rotationState: RotationState
    @Binding var questionBankMarkdown: String

    @State private var messageText: String = ""
    @State private var showSavedConfirmation: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    private let storageService = StorageService()

    // Design tokens
    private let cream = Color(hex: 0xFBF8F3)
    private let warmCharcoal = Color(hex: 0x2C2420)
    private let warmGray = Color(hex: 0x6B5E54)
    private let terracotta = Color(hex: 0xC67B5C)

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()

            VStack(spacing: 0) {
                chatArea
                inputBar
                endSessionButton
            }

            if showSavedConfirmation {
                savedOverlay
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(warmCharcoal)
                }
            }
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Show the question at the top
                    if let question = session.currentQuestion {
                        questionHeader(question)
                    }

                    ForEach(session.conversationTurns) { turn in
                        chatBubble(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .onChange(of: session.conversationTurns.count) { _, _ in
                if let lastTurn = session.conversationTurns.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastTurn.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func questionHeader(_ question: Question) -> some View {
        VStack(spacing: 8) {
            if let cat = categories[question.category] {
                Text("\(String(question.category)): \(cat.name)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(warmGray)
            }

            Text(question.text)
                .font(.title3)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(terracotta.opacity(0.08))
        )
    }

    @ViewBuilder
    private func chatBubble(for turn: ConversationTurn) -> some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 48) }

            Text(turn.text)
                .font(.body)
                .foregroundStyle(warmCharcoal)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(bubbleBackground(for: turn.role))
                .frame(maxWidth: 280, alignment: turn.role == .user ? .trailing : .leading)

            if turn.role == .assistant { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubbleBackground(for role: ConversationTurn.Role) -> some View {
        switch role {
        case .user:
            RoundedRectangle(cornerRadius: 18)
                .fill(cream)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        case .assistant:
            RoundedRectangle(cornerRadius: 18)
                .fill(.white)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Add more to your answer...", text: $messageText, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
                )

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(terracotta)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cream)
    }

    // MARK: - End Session Button

    private var endSessionButton: some View {
        Button {
            Task { await endSession() }
        } label: {
            Text("End Session & Save")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(terracotta)
                )
        }
        .disabled(session.conversationTurns.isEmpty || isSaving)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Saved Overlay

    private var savedOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(terracotta)

                Text("Answer Saved")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(warmCharcoal)

                if let error = saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
            )
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        session.addTurn(role: .user, text: text)
        messageText = ""

        // Placeholder AI response until LLM is wired up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            session.addTurn(
                role: .assistant,
                text: "Thank you for sharing more. Is there anything else you would like to add?"
            )
        }
    }

    @MainActor
    private func endSession() async {
        guard let question = session.currentQuestion else { return }
        isSaving = true

        do {
            // 1. Compile user turns into single answer text
            let answerText = session.compileAnswer()

            // 2. Determine category name
            let categoryName = categories[question.category]?.name ?? String(question.category)

            // 3. Create Answer struct
            let answer = Answer(
                questionID: question.id,
                questionText: question.text,
                categoryLetter: question.category,
                categoryName: categoryName,
                passNumber: rotationState.currentPass ?? 1,
                askedDate: Date(),
                answeredDate: Date(),
                answerText: answerText,
                followUpQuestions: [],
                source: .text
            )

            // 4. Save answer via StorageService
            try storageService.saveAnswer(answer)

            // 5. Mark question answered via RotationEngine
            if let result = RotationEngine.markAnswered(
                questionID: question.id,
                markdown: questionBankMarkdown,
                rotation: rotationState
            ) {
                questionBankMarkdown = result.updatedMarkdown
                rotationState = result.updatedRotation

                // 6. Persist updated state
                try storageService.writeQuestionBank(questionBankMarkdown)
                try storageService.writeRotationState(rotationState)

                // Update local questions array
                if let idx = questions.firstIndex(where: { $0.id == question.id }) {
                    questions[idx].answered = true
                }
            }

            // 7. Show confirmation
            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = true
            }

            // Navigate back after a brief pause
            try? await Task.sleep(for: .seconds(1.5))

            session.resetSession()

            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = false
            }

            dismiss()

        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = true
            }
            isSaving = false
        }
    }
}

#Preview {
    NavigationStack {
        ConversationView(
            questions: .constant([]),
            categories: .constant([:]),
            rotationState: .constant(.default),
            questionBankMarkdown: .constant("")
        )
        .environment(SessionState())
    }
}
