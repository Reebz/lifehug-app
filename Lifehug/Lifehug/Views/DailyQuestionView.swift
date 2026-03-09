import SwiftUI
import UIKit

struct DailyQuestionView: View {
    @Environment(SessionState.self) private var session
    @Environment(STTService.self) private var sttService
    @Environment(LLMService.self) private var llmService
    @Environment(TTSService.self) private var ttsService
    @State private var storageService = StorageService()
    @State private var questions: [Question] = []
    @State private var categories: [Character: Category] = [:]
    @State private var rotationState: RotationState = .default
    @State private var questionBankMarkdown: String = ""
    @State private var showTypeInput: Bool = false
    @State private var typedText: String = ""
    @State private var navigateToConversation: Bool = false
    @State private var loadError: String?

    // Voice session state
    @State private var voiceSessionActive: Bool = false
    @State private var pipeline: VoicePipeline?
    @State private var showSavedConfirmation: Bool = false
    @State private var voiceSessionTask: Task<Void, Never>?
    @State private var isSaving: Bool = false
    @State private var hasStartedLLMSession: Bool = false

    // Constants
    private let micDiameter: CGFloat = 200
    private let micIconSize: CGFloat = 72

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.cream.ignoresSafeArea()

                if voiceSessionActive {
                    voiceSessionContentArea
                } else {
                    idleContentArea
                }

                if showSavedConfirmation {
                    savedOverlay
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    micButton

                    if showTypeInput {
                        typeInputArea
                    } else {
                        typeInsteadButton
                    }
                }
                .padding(.bottom, 8)
                .background(
                    Theme.cream
                        .shadow(color: .black.opacity(0.04), radius: 8, y: -4)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
            .navigationDestination(isPresented: $navigateToConversation) {
                ConversationView(
                    questions: $questions,
                    categories: $categories,
                    rotationState: $rotationState,
                    questionBankMarkdown: $questionBankMarkdown
                )
            }
            .modifier(LifehugBarStyle())
        }
        .task {
            await loadQuestionData()
        }
    }

    // MARK: - Idle Content Area

    private var idleContentArea: some View {
        VStack(spacing: 32) {
            Spacer()

            questionContent

            transcriptArea

            Spacer()
        }
        .padding(.horizontal, Theme.horizontalPadding)
    }

    // MARK: - Voice Session Content Area

    private var voiceSessionContentArea: some View {
        VStack(spacing: 16) {
            // Compact question at top
            if let question = session.currentQuestion {
                VStack(spacing: 8) {
                    Text(question.text)
                        .font(Theme.title3Font)
                        .foregroundStyle(Theme.warmCharcoal)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    if let cat = categories[question.category] {
                        Text("\(String(question.category)): \(cat.name)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.walnut)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Theme.warmGray.opacity(0.1))
                            )
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, Theme.horizontalPadding)
            }

            // Transcript scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.conversationTurns) { turn in
                            voiceTranscriptBubble(for: turn)
                                .id(turn.id)
                        }

                        // Live partial transcript while listening
                        if pipeline?.state == .listening,
                           let partial = pipeline?.partialTranscript,
                           !partial.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("You:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.terracotta)
                                Text(partial)
                                    .font(Theme.bodySerifFont)
                                    .foregroundStyle(Theme.warmCharcoal.opacity(0.6))
                                    .italic()
                            }
                            .padding(.horizontal, 16)
                            .id("livePartial")
                        }

                        // Streaming LLM response while processing/speaking
                        if let pipeline,
                           (pipeline.state == .processing || pipeline.state == .speaking),
                           !pipeline.responseChunks.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("AI:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.sageGreen)
                                Text(pipeline.responseChunks)
                                    .font(Theme.bodySerifFont)
                                    .foregroundStyle(Theme.warmCharcoal.opacity(0.8))
                            }
                            .padding(.horizontal, 16)
                            .id("streamingResponse")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: session.conversationTurns.count) { _, _ in
                    if let lastTurn = session.conversationTurns.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastTurn.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: pipeline?.partialTranscript) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("livePartial", anchor: .bottom)
                    }
                }
                .onChange(of: pipeline?.responseChunks) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("streamingResponse", anchor: .bottom)
                    }
                }
            }

            // Done & Save button
            Button {
                Task { await endVoiceSessionAndSave() }
            } label: {
                Text("Done & Save")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Theme.terracotta)
                    )
            }
            .disabled(session.conversationTurns.isEmpty || isSaving)
        }
    }

    // MARK: - Voice Transcript Bubble

    @ViewBuilder
    private func voiceTranscriptBubble(for turn: ConversationTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(turn.role == .user ? "You:" : "AI:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(turn.role == .user ? Theme.terracotta : Theme.sageGreen)
            Text(turn.text)
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.warmCharcoal)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Question Content

    @ViewBuilder
    private var questionContent: some View {
        if let question = session.currentQuestion {
            VStack(spacing: 12) {
                Text(question.text)
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.warmCharcoal)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .minimumScaleFactor(0.7)

                if let cat = categories[question.category] {
                    Text("\(String(question.category)): \(cat.name)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.walnut)
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
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
        } else {
            ProgressView()
                .tint(Theme.terracotta)
        }
    }

    // MARK: - Mic Button Color

    private var micButtonColor: Color {
        guard voiceSessionActive, let pipeline else {
            return Theme.terracotta
        }
        switch pipeline.state {
        case .listening:
            return Theme.mutedRose
        case .speaking:
            return Theme.sageGreen
        case .processing:
            return Theme.amber
        case .idle:
            return Theme.terracotta
        }
    }

    // MARK: - Mic Button Icon

    @ViewBuilder
    private var micButtonIcon: some View {
        if voiceSessionActive, let pipeline {
            switch pipeline.state {
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.system(size: micIconSize, weight: .medium))
                    .foregroundStyle(.white)
            case .processing:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: micIconSize, weight: .medium))
                    .foregroundStyle(.white)
            case .idle:
                Image(systemName: "pause.fill")
                    .font(.system(size: micIconSize, weight: .medium))
                    .foregroundStyle(.white)
            }
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: micIconSize, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(micButtonColor)
                .frame(width: micDiameter, height: micDiameter)
                .shadow(
                    color: micButtonColor.opacity(0.15),
                    radius: (voiceSessionActive && pipeline?.state == .listening) ? 16 : 8,
                    y: 4
                )
                .scaleEffect((voiceSessionActive && pipeline?.state == .listening) ? 1.08 : 1.0)
                .animation(
                    (voiceSessionActive && pipeline?.state == .listening)
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: pipeline?.state
                )

            micButtonIcon
        }
        .contentShape(Circle())
        .onTapGesture(count: 2) {
            triggerHaptic()
            endVoiceSessionAndNavigate()
        }
        .onTapGesture(count: 1) {
            triggerHaptic()
            handleSingleTap()
        }
        .disabled(session.currentQuestion == nil)
        .accessibilityLabel(voiceSessionActive ? "Voice session active" : "Start voice session")
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
                            .foregroundStyle(Theme.walnut)
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
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .medium))
                Text("Type instead")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Theme.walnut)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(Theme.walnut.opacity(0.08)))
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
                .foregroundStyle(Theme.walnut)

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

    // MARK: - Saved Overlay

    private var savedOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.terracotta)
                Text("Answer Saved")
                    .font(Theme.title3Font)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.warmCharcoal)
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

    // MARK: - Haptic Feedback

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Voice Session Management

    private func startVoiceSession() {
        voiceSessionTask = Task {
            // Ensure LLM model is loaded
            if !llmService.isLoaded {
                try? await llmService.loadModel()
            }

            guard !Task.isCancelled else { return }

            // Create pipeline and wire callbacks
            let pipe = VoicePipeline(sttService: sttService, llmService: llmService, ttsService: ttsService)
            pipe.autoReopenMic = true

            pipe.onTranscriptFinalized = { text in
                session.addTurn(role: .user, text: text)
            }
            pipe.onResponseGenerated = { text in
                session.addTurn(role: .assistant, text: text)
            }
            pipe.onTerminationDetected = {
                Task { await endVoiceSessionAndSave() }
            }

            // Wire auto-reopen (added by parallel agent)
            pipe.wireAutoReopen()

            // Start LLM session if needed
            if !hasStartedLLMSession {
                let userName = (try? storageService.readConfig().name) ?? "friend"
                let prompt = LLMService.memoirInterviewerPrompt(
                    userName: userName,
                    questionText: session.currentQuestion?.text ?? ""
                )
                llmService.startNewSession(systemPrompt: prompt)
                hasStartedLLMSession = true
            }

            pipeline = pipe

            withAnimation(.easeOut(duration: 0.3)) {
                voiceSessionActive = true
            }

            pipe.startListening()
        }
    }

    private func endVoiceSession() {
        voiceSessionTask?.cancel()
        voiceSessionTask = nil
        pipeline?.unwireAutoReopen()
        pipeline?.stopAll()

        withAnimation(.easeOut(duration: 0.3)) {
            voiceSessionActive = false
        }

        pipeline = nil
    }

    private func endVoiceSessionAndNavigate() {
        let hasTurns = !session.conversationTurns.isEmpty

        voiceSessionTask?.cancel()
        voiceSessionTask = nil
        pipeline?.unwireAutoReopen()
        pipeline?.stopAll()

        withAnimation(.easeOut(duration: 0.3)) {
            voiceSessionActive = false
        }

        pipeline = nil

        if hasTurns {
            navigateToConversation = true
        }
    }

    @MainActor
    private func endVoiceSessionAndSave() async {
        guard !isSaving else { return }
        guard let question = session.currentQuestion else { return }
        isSaving = true

        // Stop pipeline
        voiceSessionTask?.cancel()
        voiceSessionTask = nil
        pipeline?.unwireAutoReopen()
        pipeline?.stopAll()

        do {
            // Compile answer from session turns
            let answerText = session.compileAnswer()

            let categoryName = categories[question.category]?.name ?? String(question.category)

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
                source: .voice
            )

            try storageService.saveAnswer(answer)

            // Mark question answered
            if let result = RotationEngine.markAnswered(
                questionID: question.id,
                markdown: questionBankMarkdown,
                rotation: rotationState
            ) {
                questionBankMarkdown = result.updatedMarkdown
                rotationState = result.updatedRotation

                try storageService.writeQuestionBank(questionBankMarkdown)
                try storageService.writeRotationState(rotationState)

                if let idx = questions.firstIndex(where: { $0.id == question.id }) {
                    questions[idx].answered = true
                }
            }

            // Show saved confirmation
            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = true
                voiceSessionActive = false
            }

            pipeline = nil
            isSaving = false

            // Brief pause then reset
            try? await Task.sleep(for: .seconds(1.5))

            session.resetSession()
            hasStartedLLMSession = false

            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = false
            }

            // Pick next question
            pickTodayQuestion()

        } catch {
            isSaving = false
            withAnimation(.easeOut(duration: 0.3)) {
                voiceSessionActive = false
            }
            pipeline = nil
            loadError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func handleSingleTap() {
        if !voiceSessionActive {
            startVoiceSession()
        } else if let pipeline {
            switch pipeline.state {
            case .listening:
                sttService.stopListening()
            case .speaking:
                pipeline.interrupt()
            case .idle, .processing:
                pipeline.startListening()
            }
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
        .environment(STTService())
        .environment(LLMService())
        .environment(TTSService())
}
