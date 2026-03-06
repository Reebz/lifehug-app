import Testing
import Foundation
@testable import Lifehug

@Suite("Answer Serialization")
struct AnswerTests {

    @Test("Answer roundtrip: write then read matches")
    func roundtrip() {
        let answer = Answer(
            questionID: "A1",
            questionText: "What's your earliest memory?",
            categoryLetter: "A",
            categoryName: "Origins",
            passNumber: 1,
            askedDate: makeDate("2026-03-01"),
            answeredDate: makeDate("2026-03-01"),
            answerText: "I remember sitting in my grandmother's kitchen. The smell of bread. Yellow wallpaper.",
            followUpQuestions: [
                Answer.FollowUpQuestion(id: "A6", text: "What did your grandmother's kitchen look like?"),
                Answer.FollowUpQuestion(id: "A7", text: "How did being in that kitchen make you feel?"),
            ],
            source: .voice
        )

        let markdown = answer.toMarkdown()

        // Verify format matches repo spec
        #expect(markdown.contains("# Question A1: What's your earliest memory?"))
        #expect(markdown.contains("**Category:** A (Origins) | **Pass:** 1"))
        #expect(markdown.contains("**Asked:** 2026-03-01 | **Answered:** 2026-03-01"))
        #expect(markdown.contains("I remember sitting in my grandmother's kitchen."))
        #expect(markdown.contains("## Follow-up Questions Generated"))
        #expect(markdown.contains("- A6: \"What did your grandmother's kitchen look like?\""))
        #expect(markdown.contains("**Source:** voice message (transcribed)"))

        // Parse it back
        let parsed = Answer.fromMarkdown(markdown)
        #expect(parsed != nil)
        #expect(parsed!.questionID == "A1")
        #expect(parsed!.questionText == "What's your earliest memory?")
        #expect(parsed!.categoryName == "Origins")
        #expect(parsed!.passNumber == 1)
        #expect(parsed!.answerText.contains("grandmother's kitchen"))
        #expect(parsed!.followUpQuestions.count == 2)
        #expect(parsed!.followUpQuestions[0].id == "A6")
        #expect(parsed!.source == .voice)
    }

    @Test("Answer without follow-ups or voice source")
    func simpleAnswer() {
        let answer = Answer(
            questionID: "B1",
            questionText: "When did you first feel like you had agency?",
            categoryLetter: "B",
            categoryName: "Becoming",
            passNumber: 1,
            askedDate: makeDate("2026-03-02"),
            answeredDate: makeDate("2026-03-02"),
            answerText: "When I got my first job at 16.",
            followUpQuestions: [],
            source: .text
        )

        let markdown = answer.toMarkdown()
        #expect(!markdown.contains("Follow-up Questions Generated"))
        #expect(!markdown.contains("voice message"))

        let parsed = Answer.fromMarkdown(markdown)
        #expect(parsed != nil)
        #expect(parsed!.followUpQuestions.isEmpty)
        #expect(parsed!.source == .text)
    }

    @Test("Format matches desktop tool spec")
    func formatCompatibility() {
        let answer = Answer(
            questionID: "C3",
            questionText: "How did your upbringing affect relationships?",
            categoryLetter: "C",
            categoryName: "Relationships & People",
            passNumber: 1,
            askedDate: makeDate("2026-03-05"),
            answeredDate: makeDate("2026-03-05"),
            answerText: "My parents were always fighting. I learned to be a peacekeeper.",
            followUpQuestions: [],
            source: .text
        )

        let lines = answer.toMarkdown().components(separatedBy: "\n")

        // Line 1: header
        #expect(lines[0].hasPrefix("# Question C3:"))

        // Line 2: category + pass
        #expect(lines[1].hasPrefix("**Category:**"))
        #expect(lines[1].contains("| **Pass:**"))

        // Line 3: dates
        #expect(lines[2].hasPrefix("**Asked:**"))
        #expect(lines[2].contains("| **Answered:**"))

        // Separator lines
        let separators = lines.filter { $0.trimmingCharacters(in: .whitespaces) == "---" }
        #expect(separators.count >= 2)
    }

    private func makeDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string) ?? Date()
    }
}
