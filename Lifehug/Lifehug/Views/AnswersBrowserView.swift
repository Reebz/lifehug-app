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
            .modifier(LifehugBarStyle())
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
                .listRowSeparatorTint(Theme.warmGray.opacity(0.15))
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { loadAnswers() }
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
                .padding(.bottom, 12)

                // Warm divider (Issue 22)
                Rectangle()
                    .fill(Theme.terracotta.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)

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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
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
    @State private var provenance: ChapterProvenance?
    @State private var chapterRecord: ChapterRecord?
    @State private var isGenerating = false
    @State private var currentPass: ChapterGenerator.Pass?
    @State private var generationError: String?
    @State private var showRegenConfirm = false
    @State private var showFacingPage = false

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
                            chapterStatusBadge
                            Button("Regenerate") {
                                regenerateTapped()
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

                        // Facing-page verbatim view (U12) — available once provenance exists.
                        if let provenance, !provenance.passages.isEmpty {
                            Button {
                                showFacingPage = true
                            } label: {
                                Label("See it in their words", systemImage: "text.book.closed")
                                    .font(Theme.captionSerifFont)
                                    .foregroundStyle(Theme.terracotta)
                            }
                        }

                        // Consent / finalization (U11).
                        consentSection
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
        .modifier(LifehugBarStyle())
        .task {
            loadExistingDraft()
        }
        .confirmationDialog(
            "Regenerate this chapter?",
            isPresented: $showRegenConfirm,
            titleVisibility: .visible
        ) {
            Button("Regenerate & Reset Approvals", role: .destructive) { generateDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This chapter has approved passages. Regenerating writes a new draft and resets every passage to unresolved. This cannot be undone.")
        }
        .navigationDestination(isPresented: $showFacingPage) {
            if let provenance {
                FacingPageView(provenance: provenance, answers: allAnswers, storage: storage)
            }
        }
    }

    // MARK: - Consent / Finalization (U11)

    @ViewBuilder
    private var chapterStatusBadge: some View {
        if let status = chapterRecord?.status {
            let (label, color): (String, Color) = {
                switch status {
                case .draft: return ("Draft", Theme.walnut)
                case .inReview: return ("In review", Theme.amber)
                case .ratified: return ("Ratified", Theme.sageGreen)
                }
            }()
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.14)))
        }
    }

    @ViewBuilder
    private var consentSection: some View {
        if let provenance, !provenance.passages.isEmpty {
            let record = chapterRecord
            VStack(alignment: .leading, spacing: 12) {
                if record?.status == .ratified {
                    Label("This chapter is final.", systemImage: "checkmark.seal.fill")
                        .font(Theme.captionSerifFont)
                        .foregroundStyle(Theme.sageGreen)
                } else if record?.status == .inReview {
                    Text("Review each passage")
                        .font(Theme.subheadlineSerifFont)
                        .foregroundStyle(Theme.warmCharcoal)

                    ForEach(provenance.passages, id: \.id) { passage in
                        passageReviewRow(passage)
                    }

                    Button {
                        ratifyChapter()
                    } label: {
                        Text("Finalize Chapter")
                            .font(Theme.bodySerifFont.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.buttonCornerRadius)
                                    .fill((chapterRecord?.allResolved ?? false) ? Theme.terracotta : Theme.terracotta.opacity(0.4))
                            )
                    }
                    .disabled(!(chapterRecord?.allResolved ?? false))
                } else {
                    // Draft (interim) — offer to start finalization, but show no consent prompt.
                    Button {
                        beginReview()
                    } label: {
                        Label("Review & Finalize", systemImage: "checklist")
                            .font(Theme.bodySerifFont.weight(.medium))
                            .foregroundStyle(Theme.terracotta)
                    }
                }
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

    @ViewBuilder
    private func passageReviewRow(_ passage: ChapterProvenance.PassageProvenance) -> some View {
        let resolution = chapterRecord?.passages.first { $0.passageID == passage.id }
        let state = resolution?.state ?? .unresolved
        VStack(alignment: .leading, spacing: 8) {
            Text(passage.text)
                .font(Theme.captionSerifFont)
                .foregroundStyle(Theme.warmCharcoal)
                .lineLimit(4)

            HStack(spacing: 8) {
                resolutionButton("Approve", .approved, state, Theme.sageGreen, passage.id)
                resolutionButton("Reject", .rejected, state, Theme.mutedRose, passage.id)
                resolutionButton("Change", .changeRequested, state, Theme.amber, passage.id)
                Spacer()
                if state != .unresolved {
                    Image(systemName: stateIcon(state))
                        .foregroundStyle(stateColor(state))
                }
            }

            if state == .changeRequested {
                TextField("What to change", text: noteBinding(for: passage.id), axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warmGray.opacity(0.08)))
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.warmGray.opacity(0.12)).frame(height: 1)
        }
    }

    private func resolutionButton(
        _ label: String,
        _ target: ChapterRecord.PassageResolution.State,
        _ current: ChapterRecord.PassageResolution.State,
        _ color: Color,
        _ passageID: String
    ) -> some View {
        Button {
            resolvePassage(passageID, target)
        } label: {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(current == target ? .white : color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(current == target ? color : color.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func stateIcon(_ state: ChapterRecord.PassageResolution.State) -> String {
        switch state {
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .changeRequested: return "pencil.circle.fill"
        case .unresolved: return "circle"
        }
    }

    private func stateColor(_ state: ChapterRecord.PassageResolution.State) -> Color {
        switch state {
        case .approved: return Theme.sageGreen
        case .rejected: return Theme.mutedRose
        case .changeRequested: return Theme.amber
        case .unresolved: return Theme.walnut
        }
    }

    private func noteBinding(for passageID: String) -> Binding<String> {
        Binding(
            get: { chapterRecord?.passages.first { $0.passageID == passageID }?.note ?? "" },
            set: { newValue in
                guard var record = chapterRecord else { return }
                record.resolve(passageID: passageID, state: .changeRequested, note: newValue, now: Date())
                chapterRecord = record
                try? storage.saveChapterRecord(record)
            }
        )
    }

    private func beginReview() {
        guard let provenance else { return }
        var record = chapterRecord ?? ChapterRecord.newDraft(categoryLetter: category.id, now: Date())
        record.beginReview(passageIDs: provenance.passages.map(\.id), now: Date())
        chapterRecord = record
        try? storage.saveChapterRecord(record)
    }

    private func resolvePassage(_ passageID: String, _ state: ChapterRecord.PassageResolution.State) {
        guard var record = chapterRecord else { return }
        let existingNote = record.passages.first { $0.passageID == passageID }?.note ?? ""
        record.resolve(passageID: passageID, state: state, note: existingNote, now: Date())
        chapterRecord = record
        try? storage.saveChapterRecord(record)
    }

    private func ratifyChapter() {
        guard var record = chapterRecord else { return }
        if record.ratify(now: Date()) {
            chapterRecord = record
            try? storage.saveChapterRecord(record)
        }
    }

    /// Regenerate gate (KTD15/AE6): confirm when approvals would be reset; otherwise regenerate.
    private func regenerateTapped() {
        if chapterRecord?.hasAnyApproval == true || chapterRecord?.status == .ratified {
            showRegenConfirm = true
        } else {
            generateDraft()
        }
    }

    private func loadExistingDraft() {
        do {
            draft = try storage.readDraft(categoryLetter: category.id)
        } catch {
            draft = nil
        }
        provenance = storage.readProvenance(categoryLetter: category.id)
        chapterRecord = storage.readChapterRecord(categoryLetter: category.id)
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

                // Compute + persist provenance post-hoc (U10). A failed provenance write
                // surfaces (KTD16) rather than silently dropping.
                let sourceSegments = ChapterGenerator.sourceSegments(from: answers)
                let computed = ChapterGenerator.computeProvenance(
                    draft: chapterDraft, segments: sourceSegments, categoryLetter: category.id
                )
                do {
                    try storage.saveProvenance(computed)
                    provenance = computed
                } catch {
                    generationError = "Chapter saved, but its source links could not be written: \(error.localizedDescription)"
                }

                // Consent record (KTD15): a (re)generated draft resets every passage to
                // unresolved and returns the chapter to draft status.
                var record = chapterRecord ?? ChapterRecord.newDraft(categoryLetter: category.id, now: Date())
                record.resetForRegeneration(newPassageIDs: computed.passages.map(\.id), now: Date())
                try? storage.saveChapterRecord(record)
                chapterRecord = record

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
    @State private var displayText: String = ""
    // Live segment list (U5/U6): starts from `answer`, refreshed after a retry fills text.
    @State private var displaySegments: [Answer.Segment] = []
    @State private var clipPlayer = AudioClipPlayer()
    @State private var retrying: Set<String> = []
    @State private var attentionClips: Set<String> = []
    @State private var showDeleteAnswerConfirm = false
    @State private var showDeleteAudioConfirm = false
    @Environment(STTService.self) private var sttService
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
                    Text(displayText)
                        .font(Theme.bodySerifFont)
                        .foregroundStyle(Theme.warmCharcoal)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                        )
                }

                // Voice recordings (U5 recovery + U6 playback)
                voiceSegmentsSection

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

                // Delete controls (U7) — the app's first destructive answer operations.
                if !isEditing {
                    deleteControls
                }
            }
            .padding()
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationTitle("Answer")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(LifehugBarStyle())
        .confirmationDialog("Delete this answer?", isPresented: $showDeleteAnswerConfirm, titleVisibility: .visible) {
            Button("Delete Answer & Recordings", role: .destructive) { deleteWholeAnswer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasClips
                 ? "This permanently deletes the written answer and its voice recordings. This cannot be undone."
                 : "This permanently deletes the answer. This cannot be undone.")
        }
        .confirmationDialog("Delete the recordings?", isPresented: $showDeleteAudioConfirm, titleVisibility: .visible) {
            Button("Delete Recordings", role: .destructive) { deleteAnswerAudio() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the voice recordings but keeps the written answer. This cannot be undone.")
        }
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
        .onAppear {
            displayText = answer.answerText
            displaySegments = answer.segments
            attentionClips = loadAttentionClips()
            // Refuse playback while a recording session is live (KTD11).
            clipPlayer.recordingActive = { [weak sttService] in sttService?.isRecording ?? false }
        }
        .onDisappear {
            clipPlayer.stop()
        }
    }

    // MARK: - Voice Segments (U5 recovery + U6 playback)

    @ViewBuilder
    private var voiceSegmentsSection: some View {
        let voiceRows = displaySegments.enumerated().filter { $0.element.source == .voice }
        if !voiceRows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Voice Recordings")
                        .font(Theme.subheadlineSerifFont)
                        .foregroundStyle(Theme.warmCharcoal)
                    Spacer()
                    if displaySegments.contains(where: { $0.clipFilename != nil }) {
                        Button {
                            toggleAnswerPlayback()
                        } label: {
                            Image(systemName: clipPlayer.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.terracotta)
                        }
                        .accessibilityLabel(clipPlayer.state == .playing ? "Pause playback" : "Play all recordings")
                    }
                }

                if clipPlayer.refusedWhileRecording {
                    Text("Finish recording before playing back.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedRose)
                }

                ForEach(voiceRows, id: \.offset) { _, seg in
                    segmentRow(seg)
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
    }

    @ViewBuilder
    private func segmentRow(_ seg: Answer.Segment) -> some View {
        let isCurrent = seg.clipFilename != nil && clipPlayer.currentClipName == seg.clipFilename
        HStack(alignment: .top, spacing: 10) {
            if let clip = seg.clipFilename, let url = try? storage.clipURL(filename: clip) {
                Button {
                    clipPlayer.play([(clip, url)])
                } label: {
                    Image(systemName: isCurrent && clipPlayer.state == .playing ? "waveform.circle.fill" : "play.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.terracotta)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play this recording")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(seg.text.isEmpty ? "(no transcription yet)" : seg.text)
                    .font(Theme.captionSerifFont)
                    .foregroundStyle(seg.text.isEmpty ? Theme.softGray : Theme.warmCharcoal)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    if seg.isEdited {
                        segmentBadge("Edited", Theme.walnut)
                    }
                    if seg.needsTranscription {
                        let needsAttention = seg.clipFilename.map { attentionClips.contains($0) } ?? false
                        segmentBadge(needsAttention ? "Needs attention" : "Needs transcription",
                                     needsAttention ? Theme.mutedRose : Theme.amber)
                    }
                }
            }

            Spacer(minLength: 8)

            if seg.needsTranscription, let clip = seg.clipFilename {
                if retrying.contains(clip) {
                    ProgressView().controlSize(.small).tint(Theme.terracotta)
                } else {
                    Button("Retry") {
                        Task { await retrySegment(clip) }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.terracotta)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Theme.terracotta.opacity(0.08) : .clear)
        )
    }

    private func segmentBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func toggleAnswerPlayback() {
        switch clipPlayer.state {
        case .playing, .paused:
            clipPlayer.togglePlayPause()
        case .idle, .finished:
            let clips = AudioClipPlayer.playableClips(from: displaySegments) { try? storage.clipURL(filename: $0) }
            clipPlayer.play(clips)
        }
    }

    private func retrySegment(_ clip: String) async {
        retrying.insert(clip)
        defer { retrying.remove(clip) }
        let coordinator = TranscriptionRetryCoordinator(storage: storage, stt: sttService)
        await coordinator.manualRetry(clipFilename: clip, questionID: answer.questionID)
        reloadFromDisk()
    }

    private func reloadFromDisk() {
        guard let url = try? storage.answerURL(questionID: answer.questionID),
              let fresh = try? storage.readAnswer(at: url) else { return }
        displaySegments = fresh.segments
        displayText = fresh.answerText
        attentionClips = loadAttentionClips()
        onSave()
    }

    private func loadAttentionClips() -> Set<String> {
        let queue = TranscriptionRetryStore(storage: storage).load()
        return Set(queue.jobs.filter { $0.status == .needsAttention }.map(\.clipFilename))
    }

    // MARK: - Delete (U7)

    private var hasClips: Bool {
        displaySegments.contains { $0.clipFilename != nil }
    }

    @ViewBuilder
    private var deleteControls: some View {
        VStack(spacing: 10) {
            if hasClips {
                Button(role: .destructive) {
                    showDeleteAudioConfirm = true
                } label: {
                    Label("Delete Recordings Only", systemImage: "waveform.slash")
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Theme.mutedRose)
            }
            Button(role: .destructive) {
                showDeleteAnswerConfirm = true
            } label: {
                Label("Delete Answer", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Theme.mutedRose)
        }
        .padding(.top, 8)
    }

    /// The current on-disk answer (retry may have filled text since this view opened).
    private func currentAnswer() -> Answer {
        if let url = try? storage.answerURL(questionID: answer.questionID),
           let fresh = try? storage.readAnswer(at: url) {
            return fresh
        }
        return answer.replacingSegments(displaySegments)
    }

    private func deleteWholeAnswer() {
        clipPlayer.stop()
        try? storage.deleteAnswer(currentAnswer())
        onSave()
        dismiss()
    }

    private func deleteAnswerAudio() {
        clipPlayer.stop()
        if let updated = try? storage.deleteAudio(for: currentAnswer()) {
            displaySegments = updated.segments
        }
        onSave()
    }

    private func saveEditedAnswer() {
        // Base on the freshest on-disk answer (KTD6/KTD8): a background transcription retry may
        // have filled a segment's text while this view was open, and editing off the stale
        // in-memory snapshot would clobber it.
        let base = currentAnswer()
        let bodyChanged = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            != base.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedSegments: [Answer.Segment] = base.segments.map { seg in
            // Only mark a populated voice segment user-edited (drops it from pull-quote
            // eligibility). An empty needs-transcription segment the user never touched must
            // stay recoverable — marking it edited would permanently cancel its recovery.
            guard bodyChanged, seg.source == .voice, !seg.needsTranscription, !seg.text.isEmpty else { return seg }
            var edited = seg
            edited.isEdited = true
            return edited
        }
        let updated = Answer(
            questionID: base.questionID,
            questionText: base.questionText,
            categoryLetter: base.categoryLetter,
            categoryName: base.categoryName,
            passNumber: base.passNumber,
            askedDate: base.askedDate,
            answeredDate: base.answeredDate,
            answerText: editedText,
            followUpQuestions: base.followUpQuestions,
            source: base.source,
            segments: preservedSegments
        )
        do {
            try storage.saveAnswer(updated)
            displayText = editedText
            displaySegments = preservedSegments
            isEditing = false
            onSave()
        } catch {
            // Save failed silently for now
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }
}

#Preview {
    AnswersBrowserView()
        .environment(AppState())
        .environment(LLMService())
}
