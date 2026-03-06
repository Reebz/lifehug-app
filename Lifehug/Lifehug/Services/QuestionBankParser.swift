import Foundation

struct QuestionBankParser {

    // MARK: - Parse Categories

    /// Discover categories from question-bank.md headers like `## A: Origins (Childhood & Family)`
    /// Group assignment uses letter range only (A-E = main, F-J = project, K+ = spotlight).
    static func parseCategories(from markdown: String) -> [Character: Category] {
        let headerPattern = /^## ([A-Z]): (.+?)(?:\s*\(.*\))?\s*$/
        var categories: [Character: Category] = [:]

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = String(line).firstMatch(of: headerPattern) else { continue }
            let letter = Character(String(match.1))
            let name = String(match.2).trimmingCharacters(in: .whitespaces)
            let group = Category.groupForLetter(letter)
            categories[letter] = Category(id: letter, name: name, group: group)
        }

        return categories
    }

    // MARK: - Parse Questions

    /// Parse questions from markdown. Format: `- [ ] A1: Question text` or `- [x] A1: Question text *(date)*`
    static func parseQuestions(from markdown: String) -> [Question] {
        let pattern = /^- \[([ x])\] ([A-Z]\d+): (.+?)(?:\s*\*\(.+\)\*)?$/
        var questions: [Question] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            guard let match = lineStr.firstMatch(of: pattern) else { continue }
            let answered = String(match.1) == "x"
            let id = String(match.2)
            let text = String(match.3).trimmingCharacters(in: .whitespaces)
            guard let category = id.first else { continue }

            questions.append(Question(
                id: id,
                category: category,
                text: text,
                answered: answered
            ))
        }

        return questions
    }

    // MARK: - Mark Answered

    /// Check off a question in the markdown, adding today's date. Returns the updated markdown, or nil if not found.
    static func markAnswered(questionID: String, in markdown: String) -> String? {
        let today = Self.todayString()
        let escapedID = NSRegularExpression.escapedPattern(for: questionID)
        let pattern = "^(- \\[) \\] (\(escapedID): .+?)$"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return nil
        }

        let mutableString = NSMutableString(string: markdown)
        let range = NSRange(location: 0, length: mutableString.length)
        let count = regex.replaceMatches(
            in: mutableString,
            range: range,
            withTemplate: "$1x] $2 *(\\(today))*"
        )

        return count > 0 ? mutableString as String : nil
    }

    // MARK: - Compute Coverage

    /// Compute coverage on-the-fly from parsed questions. No persistent coverage.json needed.
    static func computeCoverage(
        questions: [Question],
        categories: [Character: Category]
    ) -> [Character: CoverageInfo] {
        var coverage: [Character: CoverageInfo] = [:]

        for (letter, _) in categories {
            let catQuestions = questions.filter { $0.category == letter }
            let total = catQuestions.count
            let answered = catQuestions.filter(\.answered).count
            coverage[letter] = CoverageInfo(total: total, answered: answered)
        }

        return coverage
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
