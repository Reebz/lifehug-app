import SwiftUI

struct DailyQuestionView: View {
    @Environment(SessionState.self) private var session
    @Environment(STTService.self) private var sttService
    @State private var storageService = StorageService()
    @State private var recordingTask: Task<Void, Never>?
    @State private var questions: [Question] = []
    @State private var categories: [Character: Category] = [:]
    @State private var rotationState: RotationState = .default
    @State private var questionBankMarkdown: String = ""
    @State private var showTypeInput: Bool = false
    @State private var typedText: String = ""
    @State private var navigateToConversation: Bool = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.cream.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    questionContent

                    micButton

                    transcriptArea

                    if showTypeInput {
                        typeInputArea
                    } else {
                        typeInsteadButton
                    }

                    Spacer()
                }
                .padding(.horizontal, Theme.horizontalPadding)
            }
            .navigationDestination(isPresented: $navigateToConversation) {
                ConversationView(
                    questions: $questions,
                    categories: $categories,
                    rotationState: $rotationState,
                    questionBankMarkdown: $questionBankMarkdown
                )
            }
        }
        .task {
            await loadQuestionData()
        }
    }

    // MARK: - Question Content

    @ViewBuilder
    private var questionContent: some View {
        if let question = session.currentQuestion {
            VStack(spacing: 12) {
                Text(question.text)
                    .font(Theme.title2Font)
                    .foregroundStyle(Theme.warmCharcoal)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if let cat = categories[question.category] {
                    Text("\(String(question.category)): \(cat.name)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.warmGray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Theme.warmGray.opacity(0.1))
                        )
                }
            }
        } else if let error = loadError {
            Text(error)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmGray)
                .multilineTextAlignment(.center)
        } else {
            ProgressView()
                .tint(Theme.terracotta)
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        Button {
            if session.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(session.isRecording ? Theme.softCoral : Theme.terracotta)
                    .frame(width: 80, height: 80)
                    .shadow(
                        color: (session.isRecording ? Theme.softCoral : Theme.terracotta).opacity(0.3),
                        radius: session.isRecording ? 16 : 8,
                        y: 4
                    )
                    .scaleEffect(session.isRecording ? 1.08 : 1.0)
                    .animation(
                        session.isRecording
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: session.isRecording
                    )

                Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(session.currentQuestion == nil)
        .accessibilityLabel(session.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Transcript Area

    @ViewBuilder
    private var transcriptArea: some View {
        if session.isRecording || !session.draftTranscript.isEmpty {
            VStack(spacing: 8) {
                if session.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.softCoral)
                            .frame(width: 8, height: 8)
                        Text("Listening...")
                            .font(.caption)
                            .foregroundStyle(Theme.warmGray)
                    }
                }

                if !session.draftTranscript.isEmpty {
                    Text(session.draftTranscript)
                        .font(Theme.bodySerifFont)
                        .foregroundStyle(Theme.warmCharcoal.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: session.draftTranscript)
        }
    }

    // MARK: - Type Input

    private var typeInsteadButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                showTypeInput = true
            }
        } label: {
            Text("Type instead")
                .font(.subheadline)
                .foregroundStyle(Theme.warmGray)
        }
        .buttonStyle(.plain)
        .disabled(session.currentQuestion == nil)
    }

    private var typeInputArea: some View {
        VStack(spacing: 12) {
            TextField("Type your answer...", text: $typedText, axis: .vertical)
                .lineLimit(3...6)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Theme.cardBackground)
                        .shadow(color: Theme.cardShadow, radius: 8, y: 2)
                )
                .foregroundStyle(Theme.warmCharcoal)

            HStack(spacing: 16) {
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showTypeInput = false
                        typedText = ""
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.warmGray)

                Button {
                    submitTypedAnswer()
                } label: {
                    Text("Send")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Theme.terracotta)
                        )
                }
                .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Voice Recording

    private func startRecording() {
        withAnimation(.easeOut(duration: 0.2)) {
            session.isRecording = true
        }
        session.draftTranscript = ""

        recordingTask = Task {
            if !sttService.isAuthorized {
                await sttService.requestAuthorization()
            }
            guard sttService.isAuthorized else {
                session.isRecording = false
                loadError = sttService.error ?? "Microphone or speech recognition not authorized."
                return
            }

            let stream = sttService.startListening()

            // Check if STT hit an error during startup
            if let sttError = sttService.error {
                session.isRecording = false
                loadError = sttError
                return
            }

            for await transcript in stream {
                guard !Task.isCancelled else { return }
                session.draftTranscript = transcript
            }

            guard !Task.isCancelled else { return }

            session.isRecording = false
            let text = session.draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                session.addTurn(role: .user, text: text)
                navigateToConversation = true
            }
        }
    }

    private func stopRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        sttService.stopListening()

        withAnimation(.easeOut(duration: 0.2)) {
            session.isRecording = false
        }

        let text = session.draftTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            session.addTurn(role: .user, text: text)
            navigateToConversation = true
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadQuestionData() async {
        do {
            try storageService.copyBundledQuestionBankIfNeeded()
            questionBankMarkdown = try storageService.readQuestionBank()
            categories = QuestionBankParser.parseCategories(from: questionBankMarkdown)
            questions = QuestionBankParser.parseQuestions(from: questionBankMarkdown)
            rotationState = try storageService.readRotationState()

            pickTodayQuestion()
        } catch {
            loadError = "Could not load questions. Please restart the app."
        }
    }

    private func pickTodayQuestion() {
        if let current = session.currentQuestion, !current.answered {
            return
        }

        if let next = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotationState
        ) {
            session.currentQuestion = next
        } else {
            loadError = "All questions answered! Check the coverage map."
        }
    }

    private func submitTypedAnswer() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        session.addTurn(role: .user, text: text)
        typedText = ""

        withAnimation(.easeOut(duration: 0.25)) {
            showTypeInput = false
        }

        navigateToConversation = true
    }
}

#Preview {
    DailyQuestionView()
        .environment(SessionState())
}
