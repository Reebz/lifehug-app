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

    // MARK: - Additional parsing tests

    @Test("Malformed header returns nil")
    func malformedHeaderReturnsNil() {
        let malformed = """
        Not a valid header line
        **Category:** A (Origins) | **Pass:** 1
        **Asked:** 2026-03-01 | **Answered:** 2026-03-01

        ---

        Some answer text.

        ---
        """

        let parsed = Answer.fromMarkdown(malformed)
        #expect(parsed == nil)
    }

    @Test("Empty string returns nil")
    func emptyStringReturnsNil() {
        #expect(Answer.fromMarkdown("") == nil)
        #expect(Answer.fromMarkdown("   ") == nil)
        #expect(Answer.fromMarkdown("\n") == nil)
    }

    @Test("Multiline answer text survives roundtrip")
    func multilineAnswerRoundtrip() {
        let multilineText = """
        First paragraph about childhood.

        Second paragraph about school years.
        This one has multiple lines within it
        because the memory was detailed.

        Third paragraph wrapping up.
        """

        let answer = Answer(
            questionID: "A2",
            questionText: "Tell me about where you grew up.",
            categoryLetter: "A",
            categoryName: "Origins",
            passNumber: 1,
            askedDate: makeDate("2026-03-10"),
            answeredDate: makeDate("2026-03-10"),
            answerText: multilineText,
            followUpQuestions: [],
            source: .text
        )

        let markdown = answer.toMarkdown()
        let parsed = Answer.fromMarkdown(markdown)

        #expect(parsed != nil)
        #expect(parsed!.answerText.contains("First paragraph about childhood."))
        #expect(parsed!.answerText.contains("Second paragraph about school years."))
        #expect(parsed!.answerText.contains("Third paragraph wrapping up."))
    }

    @Test("Special characters in answer text survive roundtrip")
    func specialCharactersRoundtrip() {
        let specialText = "She said, \"You'll never understand\" — and she was right. Cost me $500 & a lot of pride (100%)."

        let answer = Answer(
            questionID: "D1",
            questionText: "What's a lesson you learned the hard way?",
            categoryLetter: "D",
            categoryName: "Purpose & Calling",
            passNumber: 1,
            askedDate: makeDate("2026-03-12"),
            answeredDate: makeDate("2026-03-12"),
            answerText: specialText,
            followUpQuestions: [],
            source: .text
        )

        let markdown = answer.toMarkdown()
        let parsed = Answer.fromMarkdown(markdown)

        #expect(parsed != nil)
        #expect(parsed!.answerText.contains("\"You'll never understand\""))
        #expect(parsed!.answerText.contains("$500"))
        #expect(parsed!.answerText.contains("&"))
        #expect(parsed!.answerText.contains("(100%)"))
    }

    @Test("Answer body containing a --- horizontal rule survives roundtrip")
    func horizontalRuleInBodyRoundtrip() {
        // A life-story answer can legitimately use "---" as a divider on its own line. The
        // parser must not read that interior rule as the body's closing separator and drop
        // everything after it. Trailing follow-ups here also verify the LAST "---" (not the
        // interior one) is chosen as the closing separator.
        let bodyWithRule = """
        Before the rule.

        ---

        After the rule.
        """
        let answer = Answer(
            questionID: "A3",
            questionText: "Tell me a two-part story.",
            categoryLetter: "A",
            categoryName: "Origins",
            passNumber: 1,
            askedDate: makeDate("2026-03-15"),
            answeredDate: makeDate("2026-03-15"),
            answerText: bodyWithRule,
            followUpQuestions: [
                Answer.FollowUpQuestion(id: "A6", text: "What changed between the two parts?")
            ],
            source: .voice
        )
        let parsed = Answer.fromMarkdown(answer.toMarkdown())
        #expect(parsed != nil)
        #expect(parsed!.answerText == bodyWithRule)
        #expect(parsed!.followUpQuestions.count == 1)
    }

    @Test("Answer body ending in a --- rule with no trailing sections survives roundtrip")
    func horizontalRuleAtBodyEndRoundtrip() {
        let bodyEndingInRule = """
        Just a thought.

        ---
        """
        let answer = Answer(
            questionID: "B2",
            questionText: "Q",
            categoryLetter: "B",
            categoryName: "Becoming",
            passNumber: 1,
            askedDate: makeDate("2026-03-16"),
            answeredDate: makeDate("2026-03-16"),
            answerText: bodyEndingInRule,
            followUpQuestions: [],
            source: .text
        )
        let parsed = Answer.fromMarkdown(answer.toMarkdown())
        #expect(parsed != nil)
        #expect(parsed!.answerText == bodyEndingInRule)
    }

    // MARK: - Voice Clip Segments (U4)

    @Test("Segments round-trip through markdown with all flags")
    func segmentsRoundtrip() {
        let clip0 = "A1-\(UUID().uuidString)-0.m4a"
        let clip2 = "A1-\(UUID().uuidString)-2.m4a"
        let clip3 = "A1-\(UUID().uuidString)-3.m4a"
        let segments: [Answer.Segment] = [
            .init(text: "First spoken turn.", clipFilename: clip0, source: .voice),
            .init(text: "A typed addition.", clipFilename: nil, source: .text),
            .init(text: "", clipFilename: clip2, source: .voice, needsTranscription: true),
            .init(text: "Edited over time.", clipFilename: clip3, source: .voice, isEdited: true),
        ]
        let answer = Answer(
            questionID: "A1", questionText: "Q", categoryLetter: "A", categoryName: "Origins",
            passNumber: 1, askedDate: makeDate("2026-03-01"), answeredDate: makeDate("2026-03-01"),
            answerText: "First spoken turn.\n\nA typed addition.\n\nEdited over time.",
            followUpQuestions: [], source: .voice, segments: segments
        )

        let md = answer.toMarkdown()
        #expect(md.contains("## Voice Clips"))

        let parsed = Answer.fromMarkdown(md)
        #expect(parsed != nil)
        #expect(parsed!.segments == segments)
    }

    @Test("Pre-feature answer parses with no segments and stays intact")
    func preFeatureNoSegments() {
        let legacy = """
        # Question A1: What's your earliest memory?
        **Category:** A (Origins) | **Pass:** 1
        **Asked:** 2026-03-01 | **Answered:** 2026-03-01

        ---

        I remember the garden.

        ---

        **Source:** voice message (transcribed)
        """
        let parsed = Answer.fromMarkdown(legacy)
        #expect(parsed != nil)
        #expect(parsed!.segments.isEmpty)
        #expect(parsed!.answerText == "I remember the garden.")
        #expect(parsed!.source == .voice)
    }

    @Test("Voice Clips section does not truncate the answer body")
    func segmentSectionDoesNotTruncateBody() {
        let segments: [Answer.Segment] = [
            .init(text: "Body sentence one.", clipFilename: "A1-\(UUID().uuidString)-0.m4a", source: .voice)
        ]
        let answer = Answer(
            questionID: "A1", questionText: "Q", categoryLetter: "A", categoryName: "Origins",
            passNumber: 1, askedDate: makeDate("2026-03-01"), answeredDate: makeDate("2026-03-01"),
            answerText: "Body sentence one.", followUpQuestions: [], source: .voice, segments: segments
        )
        let parsed = Answer.fromMarkdown(answer.toMarkdown())
        #expect(parsed!.answerText == "Body sentence one.")
    }

    @Test("Multi-line segment text with a backslash survives escaping")
    func multilineSegmentText() {
        let text = "Line one.\nLine two.\n\nParagraph two with a backslash \\ and more."
        let segments: [Answer.Segment] = [
            .init(text: text, clipFilename: "A1-\(UUID().uuidString)-0.m4a", source: .voice)
        ]
        let answer = Answer(
            questionID: "A1", questionText: "Q", categoryLetter: "A", categoryName: "Origins",
            passNumber: 1, askedDate: makeDate("2026-03-01"), answeredDate: makeDate("2026-03-01"),
            answerText: text, followUpQuestions: [], source: .voice, segments: segments
        )
        let parsed = Answer.fromMarkdown(answer.toMarkdown())
        #expect(parsed!.segments.count == 1)
        #expect(parsed!.segments[0].text == text)
    }

    @Test("Typed-only answer writes no Voice Clips section")
    func typedOnlyNoSection() {
        let segments: [Answer.Segment] = [
            .init(text: "Just typed.", clipFilename: nil, source: .text)
        ]
        let answer = Answer(
            questionID: "B1", questionText: "Q", categoryLetter: "B", categoryName: "Becoming",
            passNumber: 1, askedDate: makeDate("2026-03-01"), answeredDate: makeDate("2026-03-01"),
            answerText: "Just typed.", followUpQuestions: [], source: .text, segments: segments
        )
        let md = answer.toMarkdown()
        #expect(!md.contains("## Voice Clips"))
        let parsed = Answer.fromMarkdown(md)
        #expect(parsed!.segments.isEmpty)
        #expect(parsed!.answerText == "Just typed.")
    }

    // MARK: - Helpers

    private func makeDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string) ?? Date()
    }
}
