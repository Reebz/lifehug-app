import SwiftUI

struct CoverageView: View {
    @Environment(AppState.self) private var appState

    @State private var categories: [Character: Category] = [:]
    @State private var questions: [Question] = []
    @State private var coverage: [Character: CoverageInfo] = [:]
    @State private var selectedCategory: Character?

    private let storage = StorageService()

    // MARK: - Colors

    private let creamBackground = Color(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255)
    private let warmCharcoal = Color(red: 0x2C / 255, green: 0x24 / 255, blue: 0x20 / 255)
    private let warmGray = Color(red: 0x6B / 255, green: 0x5E / 255, blue: 0x54 / 255)
    private let terracotta = Color(red: 0xC6 / 255, green: 0x7B / 255, blue: 0x5C / 255)
    private let sageGreen = Color(red: 0x7B / 255, green: 0xA1 / 255, blue: 0x7D / 255)
    private let amber = Color(red: 0xD4 / 255, green: 0xA8 / 255, blue: 0x55 / 255)
    private let mutedRose = Color(red: 0xC4 / 255, green: 0x70 / 255, blue: 0x70 / 255)

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
            .background(creamBackground.ignoresSafeArea())
            .navigationTitle("Coverage")
            .sheet(item: categoryBinding) { wrapper in
                CategoryDetailSheet(
                    category: wrapper.category,
                    questions: questions.filter { $0.category == wrapper.id },
                    categoryColor: colorForCategory(wrapper.id),
                    creamBackground: creamBackground,
                    warmCharcoal: warmCharcoal,
                    warmGray: warmGray,
                    terracotta: terracotta
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
                        .foregroundStyle(warmGray)
                }

                Text("\(String(letter)): \(cat.name)")
                    .font(.subheadline)
                    .fontDesign(.serif)
                    .foregroundStyle(warmCharcoal)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("\(info.answered)/\(info.total)")
                    .font(.title3.bold())
                    .foregroundStyle(warmCharcoal)
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
                .font(.subheadline)
                .fontDesign(.serif)
                .foregroundStyle(warmGray)

            Text("\(totalAnswered) / \(totalQuestions)")
                .font(.title.bold())
                .foregroundStyle(warmCharcoal)

            if totalQuestions > 0 {
                SwiftUI.ProgressView(value: Double(totalAnswered), total: Double(totalQuestions))
                    .tint(terracotta)
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
        case .green: sageGreen
        case .yellow: amber
        case .red: mutedRose
        }
    }

    private func colorForCategory(_ letter: Character) -> Color {
        guard let info = coverage[letter] else { return warmGray }
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
    let creamBackground: Color
    let warmCharcoal: Color
    let warmGray: Color
    let terracotta: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(questions) { question in
                    HStack(spacing: 12) {
                        Image(systemName: question.answered ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(question.answered ? categoryColor : warmGray)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.id)
                                .font(.caption)
                                .foregroundStyle(warmGray)
                            Text(question.text)
                                .font(.body)
                                .foregroundStyle(warmCharcoal)
                        }
                    }
                    .listRowBackground(creamBackground)
                }
            }
            .scrollContentBackground(.hidden)
            .background(creamBackground.ignoresSafeArea())
            .navigationTitle("\(String(category.id)): \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(terracotta)
                }
            }
        }
    }
}

#Preview {
    CoverageView()
        .environment(AppState())
}
