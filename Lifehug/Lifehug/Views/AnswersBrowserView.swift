import SwiftUI

struct AnswersBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var answers: [Answer] = []
    @State private var selectedAnswer: Answer?
    @State private var categories: [Character: Category] = [:]
    @State private var questions: [Question] = []
    @State private var selectedSegment: BrowserSegment = .answers

    private let storage = StorageService()

    enum BrowserSegment: String, CaseIterable {
        case answers = "Answers"
        case book = "Book"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedSegment) {
                    ForEach(BrowserSegment.allCases, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 12)
                .tint(Theme.terracotta)

                Group {
                    switch selectedSegment {
                    case .answers:
                        if answers.isEmpty {
                            emptyState
                        } else {
                            answersList
                        }
                    case .book:
                        bookView
                    }
                }
            }
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle(selectedSegment == .answers ? "Your Answers" : "Your Book")
            .navigationDestination(item: $selectedAnswer) { answer in
                AnswerDetailView(
                    answer: answer,
                    storage: storage,
                    onSave: { loadAnswers() }
                )
            }
            .task {
                loadCategories()
                loadAnswers()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warmGray.opacity(0.5))
            Text("No answers yet")
                .font(Theme.title3Font)
                .foregroundStyle(Theme.warmCharcoal)
            Text("Your answers will appear here after you respond to your first question.")
                .font(Theme.bodySerifFont)
                .foregroundStyle(Theme.walnut)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Answers List

    private var answersList: some View {
        let grouped = groupedAnswers()
        let sortedKeys = grouped.keys.sorted()

        return List {
            ForEach(sortedKeys, id: \.self) { letter in
                Section {
                    ForEach(grouped[letter] ?? [], id: \.questionID) { answer in
                        answerRow(answer)
                    }
                } header: {
                    let catName = categories[letter]?.name ?? String(letter)
                    Text("\(String(letter)): \(catName)")
                        .font(Theme.subheadlineSerifFont)
                        .foregroundStyle(Theme.warmCharcoal)
                }
                .listRowBackground(Theme.cream)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func answerRow(_ answer: Answer) -> some View {
        Button {
            selectedAnswer = answer
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(answer.questionText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.warmCharcoal)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(answer.questionID)
                        .font(.caption)
                        .foregroundStyle(Theme.terracotta)

                    Text(formattedDate(answer.answeredDate))
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }

                Text(String(answer.answerText.prefix(100)))
                    .font(.caption)
                    .foregroundStyle(Theme.walnut)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Book View

    private var bookView: some View {
        let sortedCategories = categories.keys.sorted()
        let coverage = QuestionBankParser.computeCoverage(
            questions: questions,
            categories: categories
        )
        let answeredByCategory = groupedAnswers()

        return ScrollView {
            VStack(spacing: 0) {
                // Book header
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.terracotta)
                    Text("Table of Contents")
                        .font(Theme.title2Font)
                        .foregroundStyle(Theme.warmCharcoal)
                    Text("Each category becomes a chapter in your memoir.")
                        .font(Theme.captionSerifFont)
                        .foregroundStyle(Theme.walnut)
                }
                .padding(.top, 8)
                .padding(.bottom, 20)

                // Chapter list
                VStack(spacing: 12) {
                    ForEach(Array(sortedCategories.enumerated()), id: \.element) { index, letter in
                        let cat = categories[letter]!
                        let info = coverage[letter] ?? CoverageInfo(total: 0, answered: 0)
                        let answerCount = answeredByCategory[letter]?.count ?? 0

                        NavigationLink {
                            ChapterDetailView(
                                chapterNumber: index + 1,
                                category: cat,
                                coverageInfo: info,
                                answers: answeredByCategory[letter] ?? [],
                                allAnswers: answers,
                                storage: storage
                            )
                        } label: {
                            chapterRow(
                                chapterNumber: index + 1,
                                category: cat,
                                coverageInfo: info,
                                answerCount: answerCount,
                                isLocked: answerCount == 0
                            )
                        }
                        .disabled(answerCount == 0)
                    }
                }
                .padding(.horizontal, Theme.horizontalPadding)
            }
            .padding(.bottom, 24)
        }
    }

    private func chapterRow(
        chapterNumber: Int,
        category: Category,
        coverageInfo: CoverageInfo,
        answerCount: Int,
        isLocked: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(colorForStatus(coverageInfo.status))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Chapter \(chapterNumber): \(category.name)")
                    .font(Theme.bodySerifFont)
                    .foregroundStyle(isLocked ? Theme.walnut.opacity(0.4) : Theme.warmCharcoal)

                Text("\(coverageInfo.answered) of \(coverageInfo.total) questions answered")
                    .font(Theme.captionSerifFont)
                    .foregroundStyle(isLocked ? Theme.walnut.opacity(0.3) : Theme.walnut)
            }

            Spacer()

            if isLocked {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(Theme.walnut.opacity(0.3))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.walnut.opacity(0.5))
            }
        }
        .padding(Theme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(Theme.cardBackground)
                .shadow(color: Theme.cardShadow, radius: 4, y: 2)
        )
        .opacity(isLocked ? 0.6 : 1.0)
    }

    private func colorForStatus(_ status: CoverageStatus) -> Color {
        switch status {
        case .red: return Theme.mutedRose
        case .yellow: return Theme.amber
        case .green: return Theme.sageGreen
        }
    }

    // MARK: - Helpers

    private func loadCategories() {
        do {
            let markdown = try storage.readQuestionBank()
            categories = QuestionBankParser.parseCategories(from: markdown)
            questions = QuestionBankParser.parseQuestions(from: markdown)
        } catch {
            // Categories unavailable
        }
    }

    private func loadAnswers() {
        do {
            let files = try storage.listAnswerFiles()
            answers = files.compactMap { url in
                try? storage.readAnswer(at: url)
            }
        } catch {
            answers = []
        }
    }

    private func groupedAnswers() -> [Character: [Answer]] {
        Dictionary(grouping: answers, by: \.categoryLetter)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Answer Identifiable Conformance

extension Answer: Equatable {
    static func == (lhs: Answer, rhs: Answer) -> Bool {
        lhs.questionID == rhs.questionID
    }
}

extension Answer: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(questionID)
    }
}

extension Answer: Identifiable {
    var id: String { questionID }
}

// MARK: - Chapter Detail View

struct ChapterDetailView: View {
    let chapterNumber: Int
    let category: Category
    let coverageInfo: CoverageInfo
    let answers: [Answer]
    let allAnswers: [Answer]
    let storage: StorageService

    @Environment(LLMService.self) private var llmService
    @State private var draft: String?
    @State private var isGenerating = false
    @State private var currentPass: ChapterGenerator.Pass?
    @State private var generationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                // Chapter header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chapter \(chapterNumber)")
                        .font(Theme.captionSerifFont)
                        .foregroundStyle(Theme.terracotta)
                    Text(category.name)
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.warmCharcoal)
                    HStack(spacing: 12) {
                        Label(
                            "\(coverageInfo.answered)/\(coverageInfo.total) answered",
                            systemImage: "checkmark.circle"
                        )
                        Label(
                            coverageInfo.status.rawValue.capitalized,
                            systemImage: "circle.fill"
                        )
                        .foregroundStyle(chapterColorForStatus(coverageInfo.status))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.walnut)
                }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .fill(Theme.cardBackground)
                        .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                )

                // Answers in this chapter
                if !answers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Answers")
                            .font(Theme.headlineFont)
                            .foregroundStyle(Theme.warmCharcoal)

                        ForEach(answers, id: \.questionID) { answer in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(answer.questionText)
                                    .font(Theme.subheadlineSerifFont.weight(.medium))
                                    .foregroundStyle(Theme.warmCharcoal)
                                Text(answer.answerText)
                                    .font(Theme.bodySerifFont)
                                    .foregroundStyle(Theme.walnut)
                                    .lineLimit(4)
                            }
                            .padding(Theme.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .fill(Theme.cardBackground)
                                    .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                            )
                        }
                    }
                }

                // Draft section
                if let draft, !draft.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Chapter Draft")
                                .font(Theme.headlineFont)
                                .foregroundStyle(Theme.warmCharcoal)
                            Spacer()
                            Button("Regenerate") {
                                generateDraft()
                            }
                            .font(Theme.captionSerifFont)
                            .foregroundStyle(Theme.terracotta)
                        }

                        Text(draft)
                            .font(Theme.bodySerifFont)
                            .foregroundStyle(Theme.warmCharcoal)
                            .padding(Theme.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .fill(Theme.cardBackground)
                                    .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                            )
                    }
                }

                // Generation error
                if let generationError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.mutedRose)
                        Text(generationError)
                            .font(Theme.captionSerifFont)
                            .foregroundStyle(Theme.walnut)
                    }
                    .padding(Theme.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                            .fill(Theme.mutedRose.opacity(0.1))
                    )
                }

                // Generate button / progress
                if isGenerating {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Theme.terracotta)
                        if let currentPass {
                            Text(currentPass.rawValue)
                                .font(Theme.bodySerifFont)
                                .foregroundStyle(Theme.walnut)
                            // Pass indicator dots
                            HStack(spacing: 8) {
                                passDot(for: .extracting)
                                passDot(for: .outlining)
                                passDot(for: .writing)
                            }
                        } else {
                            Text("Preparing...")
                                .font(Theme.bodySerifFont)
                                .foregroundStyle(Theme.walnut)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if draft == nil {
                    Button(action: generateDraft) {
                        Text("Generate Chapter Draft")
                            .font(Theme.bodySerifFont.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.buttonCornerRadius)
                                    .fill(answers.count < 3 ? Theme.terracotta.opacity(0.4) : Theme.terracotta)
                            )
                    }
                    .disabled(answers.count < 3)
                }
            }
            .padding(Theme.horizontalPadding)
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadExistingDraft()
        }
    }

    private func loadExistingDraft() {
        do {
            draft = try storage.readDraft(categoryLetter: category.id)
        } catch {
            draft = nil
        }
    }

    private func generateDraft() {
        isGenerating = true
        draft = nil
        generationError = nil
        currentPass = nil

        Task {
            do {
                // Load model if needed
                if !llmService.isLoaded {
                    try await llmService.loadModel()
                }

                // Read user name from UserDefaults or fall back
                let userName = UserDefaults.standard.string(forKey: "userName") ?? "the author"

                let chapterDraft = try await ChapterGenerator.generate(
                    category: category,
                    answers: answers,
                    userName: userName,
                    llmService: llmService,
                    onPassChange: { pass in
                        currentPass = pass
                    }
                )

                do {
                    try storage.saveDraft(categoryLetter: category.id, content: chapterDraft)
                } catch {
                    // Save failed silently for now
                }
                draft = chapterDraft
            } catch {
                generationError = "Chapter generation failed: \(error.localizedDescription)"
            }
            isGenerating = false
            currentPass = nil
        }
    }

    private func passDot(for pass: ChapterGenerator.Pass) -> some View {
        let isActive = currentPass == pass
        let isPast: Bool = {
            guard let current = currentPass else { return false }
            let order: [ChapterGenerator.Pass] = [.extracting, .outlining, .writing]
            guard let currentIndex = order.firstIndex(of: current),
                  let passIndex = order.firstIndex(of: pass) else { return false }
            return passIndex < currentIndex
        }()

        return Circle()
            .fill(isPast ? Theme.sageGreen : (isActive ? Theme.terracotta : Theme.warmGray.opacity(0.3)))
            .frame(width: 8, height: 8)
    }

    private func chapterColorForStatus(_ status: CoverageStatus) -> Color {
        switch status {
        case .red: return Theme.mutedRose
        case .yellow: return Theme.amber
        case .green: return Theme.sageGreen
        }
    }
}

// MARK: - Answer Detail View

struct AnswerDetailView: View {
    let answer: Answer
    let storage: StorageService
    let onSave: () -> Void

    @State private var isEditing = false
    @State private var editedText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Question header
                VStack(alignment: .leading, spacing: 8) {
                    Text(answer.questionID)
                        .font(.caption)
                        .foregroundStyle(Theme.terracotta)

                    Text(answer.questionText)
                        .font(Theme.title3Font)
                        .foregroundStyle(Theme.warmCharcoal)

                    HStack(spacing: 16) {
                        Label(
                            "\(answer.categoryName.isEmpty ? String(answer.categoryLetter) : answer.categoryName)",
                            systemImage: "folder"
                        )
                        Label("Pass \(answer.passNumber)", systemImage: "arrow.counterclockwise")
                        Label(formattedDate(answer.answeredDate), systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.walnut)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                )

                // Answer content
                if isEditing {
                    TextEditor(text: $editedText)
                        .frame(minHeight: 300)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                        )
                        .foregroundStyle(Theme.warmCharcoal)
                } else {
                    Text(answer.answerText)
                        .font(.body)
                        .foregroundStyle(Theme.warmCharcoal)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                        )
                }

                // Follow-up questions
                if !answer.followUpQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Follow-up Questions")
                            .font(Theme.subheadlineSerifFont)
                            .foregroundStyle(Theme.warmCharcoal)

                        ForEach(answer.followUpQuestions, id: \.id) { fq in
                            HStack(alignment: .top, spacing: 8) {
                                Text(fq.id)
                                    .font(.caption)
                                    .foregroundStyle(Theme.terracotta)
                                Text(fq.text)
                                    .font(.caption)
                                    .foregroundStyle(Theme.walnut)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                    )
                }

                if answer.source == .voice {
                    Label("Transcribed from voice", systemImage: "mic")
                        .font(.caption)
                        .foregroundStyle(Theme.walnut)
                }
            }
            .padding()
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle("Answer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        saveEditedAnswer()
                    } else {
                        editedText = answer.answerText
                        isEditing = true
                    }
                }
                .foregroundStyle(Theme.terracotta)
            }
        }
    }

    private func saveEditedAnswer() {
        let updated = Answer(
            questionID: answer.questionID,
            questionText: answer.questionText,
            categoryLetter: answer.categoryLetter,
            categoryName: answer.categoryName,
            passNumber: answer.passNumber,
            askedDate: answer.askedDate,
            answeredDate: answer.answeredDate,
            answerText: editedText,
            followUpQuestions: answer.followUpQuestions,
            source: answer.source
        )
        do {
            try storage.saveAnswer(updated)
            isEditing = false
            onSave()
        } catch {
            // Save failed silently for now
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview {
    AnswersBrowserView()
        .environment(AppState())
        .environment(LLMService())
}
