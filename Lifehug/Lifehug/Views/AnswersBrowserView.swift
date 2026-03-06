import SwiftUI

struct AnswersBrowserView: View {
    @Environment(AppState.self) private var appState

    @State private var answers: [Answer] = []
    @State private var selectedAnswer: Answer?
    @State private var categories: [Character: Category] = [:]

    private let storage = StorageService()

    // MARK: - Colors

    private let creamBackground = Color(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255)
    private let warmCharcoal = Color(red: 0x2C / 255, green: 0x24 / 255, blue: 0x20 / 255)
    private let warmGray = Color(red: 0x6B / 255, green: 0x5E / 255, blue: 0x54 / 255)
    private let terracotta = Color(red: 0xC6 / 255, green: 0x7B / 255, blue: 0x5C / 255)

    var body: some View {
        NavigationStack {
            Group {
                if answers.isEmpty {
                    emptyState
                } else {
                    answersList
                }
            }
            .background(creamBackground.ignoresSafeArea())
            .navigationTitle("Your Answers")
            .navigationDestination(item: $selectedAnswer) { answer in
                AnswerDetailView(
                    answer: answer,
                    storage: storage,
                    creamBackground: creamBackground,
                    warmCharcoal: warmCharcoal,
                    warmGray: warmGray,
                    terracotta: terracotta,
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
                .foregroundStyle(warmGray.opacity(0.5))
            Text("No answers yet")
                .font(.title3)
                .fontDesign(.serif)
                .foregroundStyle(warmCharcoal)
            Text("Your answers will appear here after you respond to your first question.")
                .font(.body)
                .foregroundStyle(warmGray)
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
                        .font(.subheadline)
                        .fontDesign(.serif)
                        .foregroundStyle(warmCharcoal)
                }
                .listRowBackground(creamBackground)
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
                    .foregroundStyle(warmCharcoal)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(answer.questionID)
                        .font(.caption)
                        .foregroundStyle(terracotta)

                    Text(formattedDate(answer.answeredDate))
                        .font(.caption)
                        .foregroundStyle(warmGray)
                }

                Text(String(answer.answerText.prefix(100)))
                    .font(.caption)
                    .foregroundStyle(warmGray)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func loadCategories() {
        do {
            let markdown = try storage.readQuestionBank()
            categories = QuestionBankParser.parseCategories(from: markdown)
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

// MARK: - Answer Detail View

struct AnswerDetailView: View {
    let answer: Answer
    let storage: StorageService
    let creamBackground: Color
    let warmCharcoal: Color
    let warmGray: Color
    let terracotta: Color
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
                        .foregroundStyle(terracotta)

                    Text(answer.questionText)
                        .font(.title3)
                        .fontDesign(.serif)
                        .foregroundStyle(warmCharcoal)

                    HStack(spacing: 16) {
                        Label(
                            "\(answer.categoryName.isEmpty ? String(answer.categoryLetter) : answer.categoryName)",
                            systemImage: "folder"
                        )
                        Label("Pass \(answer.passNumber)", systemImage: "arrow.counterclockwise")
                        Label(formattedDate(answer.answeredDate), systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(warmGray)
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
                        .foregroundStyle(warmCharcoal)
                } else {
                    Text(answer.answerText)
                        .font(.body)
                        .foregroundStyle(warmCharcoal)
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
                            .font(.subheadline)
                            .fontDesign(.serif)
                            .foregroundStyle(warmCharcoal)

                        ForEach(answer.followUpQuestions, id: \.id) { fq in
                            HStack(alignment: .top, spacing: 8) {
                                Text(fq.id)
                                    .font(.caption)
                                    .foregroundStyle(terracotta)
                                Text(fq.text)
                                    .font(.caption)
                                    .foregroundStyle(warmGray)
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
                        .foregroundStyle(warmGray)
                }
            }
            .padding()
        }
        .background(creamBackground.ignoresSafeArea())
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
                .foregroundStyle(terracotta)
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
}
