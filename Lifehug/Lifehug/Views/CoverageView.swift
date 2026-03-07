import SwiftUI

struct CoverageView: View {
    @Environment(AppState.self) private var appState

    @State private var categories: [Character: Category] = [:]
    @State private var questions: [Question] = []
    @State private var coverage: [Character: CoverageInfo] = [:]
    @State private var selectedCategory: Character?

    private let storage = StorageService()

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    categoryGrid
                    totalAnsweredSection
                }
                .padding()
            }
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle("Coverage")
            .sheet(item: categoryBinding) { wrapper in
                CategoryDetailSheet(
                    category: wrapper.category,
                    questions: questions.filter { $0.category == wrapper.id },
                    categoryColor: colorForCategory(wrapper.id)
                )
            }
            .task {
                loadData()
            }
        }
    }

    // MARK: - Category Grid

    private var categoryGrid: some View {
        let sortedLetters = categories.keys.sorted()
        let columns = [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
        ]

        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(sortedLetters, id: \.self) { letter in
                categoryCell(letter: letter)
            }
        }
    }

    private func categoryCell(letter: Character) -> some View {
        let cat = categories[letter]!
        let info = coverage[letter] ?? CoverageInfo(total: 0, answered: 0)
        let cellColor = colorForStatus(info.status)
        let statusLabel = accessibilityLabel(for: info.status)

        return Button {
            selectedCategory = letter
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(cellColor)
                        .frame(width: 12, height: 12)
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.walnut)
                }

                Text("\(String(letter)): \(cat.name)")
                    .font(Theme.subheadlineSerifFont)
                    .foregroundStyle(Theme.warmCharcoal)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("\(info.answered)/\(info.total)")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.warmCharcoal)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(cellColor.opacity(0.4), lineWidth: 2)
            )
        }
        .accessibilityLabel("\(cat.name), \(info.answered) of \(info.total) answered, \(statusLabel)")
    }

    // MARK: - Total Answered

    private var totalAnsweredSection: some View {
        let totalAnswered = questions.filter(\.answered).count
        let totalQuestions = questions.count

        return VStack(spacing: 8) {
            Text("Total Questions Answered")
                .font(Theme.subheadlineSerifFont)
                .foregroundStyle(Theme.walnut)

            Text("\(totalAnswered) / \(totalQuestions)")
                .font(.title.bold())
                .foregroundStyle(Theme.warmCharcoal)

            if totalQuestions > 0 {
                SwiftUI.ProgressView(value: Double(totalAnswered), total: Double(totalQuestions))
                    .tint(Theme.terracotta)
                    .padding(.horizontal, 40)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }

    // MARK: - Helpers

    private func loadData() {
        do {
            let markdown = try storage.readQuestionBank()
            categories = QuestionBankParser.parseCategories(from: markdown)
            questions = QuestionBankParser.parseQuestions(from: markdown)
            coverage = QuestionBankParser.computeCoverage(questions: questions, categories: categories)
        } catch {
            // Question bank not yet available; leave empty
        }
    }

    private func colorForStatus(_ status: CoverageStatus) -> Color {
        switch status {
        case .green: Theme.sageGreen
        case .yellow: Theme.amber
        case .red: Theme.mutedRose
        }
    }

    private func colorForCategory(_ letter: Character) -> Color {
        guard let info = coverage[letter] else { return Theme.warmGray }
        return colorForStatus(info.status)
    }

    private func accessibilityLabel(for status: CoverageStatus) -> String {
        switch status {
        case .green: "Ready"
        case .yellow: "Building depth"
        case .red: "Needs answers"
        }
    }

    private var categoryBinding: Binding<CategoryWrapper?> {
        Binding<CategoryWrapper?>(
            get: {
                guard let letter = selectedCategory, let cat = categories[letter] else { return nil }
                return CategoryWrapper(id: letter, category: cat)
            },
            set: { wrapper in
                selectedCategory = wrapper?.id
            }
        )
    }
}

// MARK: - Category Wrapper (Identifiable for .sheet)

private struct CategoryWrapper: Identifiable {
    let id: Character
    let category: Category
}

// MARK: - Category Detail Sheet

private struct CategoryDetailSheet: View {
    let category: Category
    let questions: [Question]
    let categoryColor: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(questions) { question in
                    HStack(spacing: 12) {
                        Image(systemName: question.answered ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(question.answered ? categoryColor : Theme.warmGray)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.id)
                                .font(.caption)
                                .foregroundStyle(Theme.walnut)
                            Text(question.text)
                                .font(Theme.bodySerifFont)
                                .foregroundStyle(Theme.warmCharcoal)
                        }
                    }
                    .listRowBackground(Theme.cream)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle("\(String(category.id)): \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.terracotta)
                }
            }
        }
    }
}

#Preview {
    CoverageView()
        .environment(AppState())
}
