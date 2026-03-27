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

                Group {
                    if voiceSessionActive {
                        voiceSessionContentArea
                    } else {
                        idleContentArea
                    }
                }
                .animation(.easeOut(duration: 0.3), value: voiceSessionActive)

                if showSavedConfirmation {
                    savedOverlay
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    micButton

                    Text(micStateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.walnut)

                    if showTypeInput {
                        typeInputArea
                    } else {
                        // Keep typeInsteadButton in hierarchy but invisible during voice
                        // sessions to prevent safeAreaInset height change (layout jump).
                        typeInsteadButton
                            .visible(!voiceSessionActive)
                    }

                    // View Conversation button — kept in hierarchy during voice sessions
                    // for layout stability (prevents mic button from jumping vertically).
                    if !session.conversationTurns.isEmpty {
                        Button {
                            navigateToConversation = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 14, weight: .medium))
                                Text("View Conversation")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(Theme.terracotta)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .visible(!voiceSessionActive)
                    }
                }
                .padding(.bottom, 8)
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
                .id(session.currentQuestion?.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.4), value: session.currentQuestion?.id)

            // Skip question (Issue 13)
            if !voiceSessionActive && session.conversationTurns.isEmpty && session.currentQuestion != nil {
                Button {
                    skipCurrentQuestion()
                } label: {
                    Text("Skip this question")
                        .font(.caption)
                        .foregroundStyle(Theme.softGray)
                }
                .accessibilityLabel("Skip this question and load a different one")
            }

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
                            VoiceTranscriptBubble(role: turn.role, text: turn.text)
                                .id(turn.id)
                        }

                        // Live partial transcript while listening
                        if pipeline?.state == .listening,
                           let partial = pipeline?.partialTranscript,
                           !partial.isEmpty {
                            LiveTranscriptBubble(transcript: partial)
                                .id("livePartial")
                        }

                        // "Thinking..." indicator before first token
                        if let pipeline,
                           pipeline.state == .processing,
                           pipeline.responseChunks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(Theme.warmGray)
                                Text("Thinking...")
                                    .font(Theme.captionSerifFont)
                                    .foregroundStyle(Theme.warmGray)
                            }
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                        }

                        // Streaming LLM response while processing/speaking
                        if let pipeline,
                           (pipeline.state == .processing || pipeline.state == .speaking),
                           !pipeline.responseChunks.isEmpty {
                            StreamingResponseBubble(text: pipeline.responseChunks)
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

            // LLM loading indicator (Issue 5)
            if voiceSessionActive && !llmService.isLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(Theme.terracotta)
                    Text("Preparing AI responses...")
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            // Error toast (Issue 4)
            if let errorMsg = pipeline?.error {
                Text(errorMsg)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.mutedRose))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            pipeline?.error = nil
                        }
                    }
            }

            // Done & Save button
            Button {
                Task { await endVoiceSessionAndSave() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Text("Done & Save")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(isSaving ? Theme.terracotta.opacity(0.6) : Theme.terracotta)
                )
            }
            .disabled(session.conversationTurns.isEmpty || isSaving)
            .accessibilityLabel(isSaving ? "Saving your answer" : "Done and save your answer")
        }
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
            return Theme.terracotta  // Idle/not started — warm default
        }
        switch pipeline.state {
        case .listening:
            return Theme.recordingRed   // Solid RED — actively recording
        case .processing:
            return Theme.amber          // ORANGE — thinking
        case .speaking:
            return Theme.speakingGreen  // Solid GREEN — AI speaking
        case .idle:
            return Theme.amber          // ORANGE — paused/waiting
        }
    }

    private var micStateLabel: String {
        guard voiceSessionActive, let pipeline else {
            return "Tap to start"
        }
        switch pipeline.state {
        case .listening: return "Recording..."
        case .processing: return "Thinking..."
        case .speaking: return "AI speaking"
        case .idle: return "Tap to resume"
        }
    }

    // MARK: - Mic Button Icon

    @ViewBuilder
    private var micButtonIcon: some View {
        if voiceSessionActive, let pipeline {
            switch pipeline.state {
            case .listening:
                Image(systemName: "waveform")
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
                Image(systemName: "mic.fill")
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
                    radius: 8,
                    y: 4
                )

            micButtonIcon
        }
        .transaction { $0.animation = nil }
        .contentShape(Circle())
        .onTapGesture {
            triggerHaptic()
            handleSingleTap()
        }
        .disabled(session.currentQuestion == nil)
        .accessibilityLabel(micStateLabel)
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
        .accessibilityLabel("Type your answer instead of speaking")
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
                .onTapGesture { dismissSavedOverlay() }
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.terracotta)
                Text("Answer Saved")
                    .font(Theme.title3Font)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.warmCharcoal)
                Text("Tap to dismiss")
                    .font(.caption)
                    .foregroundStyle(Theme.softGray)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
            )
            .onTapGesture { dismissSavedOverlay() }
        }
        .transition(.opacity)
    }

    private func dismissSavedOverlay() {
        withAnimation(.easeOut(duration: 0.3)) {
            showSavedConfirmation = false
        }
    }

    // MARK: - Haptic Feedback

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Voice Session Management

    private func startVoiceSession() {
        // Guard against double-tap creating duplicate pipelines and STT streams
        guard !voiceSessionActive, pipeline == nil else { return }

        // Create pipeline and wire callbacks immediately (no async delay)
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

        pipe.wireAutoReopen()

        // Start LLM session if needed
        if !hasStartedLLMSession {
            let userName = storageService.readConfig().name
            let prompt = LLMService.memoirInterviewerPrompt(
                userName: userName,
                questionText: session.currentQuestion?.text ?? ""
            )
            llmService.startNewSession(systemPrompt: prompt)
            hasStartedLLMSession = true
        }

        // Order matters for instant mic button feedback:
        // 1. Assign pipeline (so micButtonColor can read pipeline.state)
        pipeline = pipe
        // 2. Start listening (sets state = .listening synchronously → mic turns red)
        pipe.startListening()
        // 3. Flip layout flag WITHOUT withAnimation — mic button color must snap instantly.
        //    Content area crossfade is handled by .animation() on the content ZStack.
        voiceSessionActive = true

        // Load LLM model in background (won't block mic)
        if !llmService.isLoaded {
            voiceSessionTask = Task {
                try? await llmService.loadModel()
            }
        }
    }

    private func endVoiceSession() {
        voiceSessionTask?.cancel()
        voiceSessionTask = nil
        pipeline?.unwireAutoReopen()
        pipeline?.stopAll()
        voiceSessionActive = false
        pipeline = nil
    }

    private func endVoiceSessionAndNavigate() {
        let hasTurns = !session.conversationTurns.isEmpty

        voiceSessionTask?.cancel()
        voiceSessionTask = nil
        pipeline?.unwireAutoReopen()
        pipeline?.stopAll()
        voiceSessionActive = false
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

            // Haptic on save success (Issue 17)
            UINotificationFeedbackGenerator().notificationOccurred(.success)

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
                pipeline.finishListening()
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
            rotationState = storageService.readRotationState()

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

    private func skipCurrentQuestion() {
        if let next = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotationState,
            excluding: session.currentQuestion?.id
        ) {
            withAnimation(.easeInOut(duration: 0.4)) {
                session.currentQuestion = next
            }
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
