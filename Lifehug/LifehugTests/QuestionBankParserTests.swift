import Testing
import Foundation
@testable import Lifehug

@Suite("QuestionBankParser")
struct QuestionBankParserTests {

    let sampleMarkdown = """
    # Life Hug — Question Bank

    Pass 1: Skeleton

    ---

    ## A: Origins (Childhood & Family)
    - [ ] A1: What's your earliest memory?
    - [ ] A2: Tell me about where you grew up.
    - [x] A3: What was your family's financial situation? *(2026-03-01)*

    ## B: Becoming (Growing Up & Finding Direction)
    - [ ] B1: When did you first feel like you had agency?
    - [x] B2: Tell me about your first job. *(2026-03-02)*

    ## F: The Problem
    - [ ] F1: What's broken in the world that you're trying to fix?

    ## K: Spotlight on Dad
    - [ ] K1: Tell me about a time your dad surprised you.
    """

    @Test("Parse categories discovers all categories with correct groups")
    func parseCategories() {
        let categories = QuestionBankParser.parseCategories(from: sampleMarkdown)

        #expect(categories.count == 4)
        #expect(categories["A"]?.name == "Origins")
        #expect(categories["A"]?.group == .main)
        #expect(categories["B"]?.name == "Becoming")
        #expect(categories["B"]?.group == .main)
        #expect(categories["F"]?.name == "The Problem")
        #expect(categories["F"]?.group == .project)
        #expect(categories["K"]?.name == "Spotlight on Dad")
        #expect(categories["K"]?.group == .spotlight)
    }

    @Test("Parse questions extracts all questions with correct status")
    func parseQuestions() {
        let questions = QuestionBankParser.parseQuestions(from: sampleMarkdown)

        #expect(questions.count == 7)

        #expect(questions[0].id == "A1")
        #expect(questions[0].category == "A")
        #expect(questions[0].answered == false)
        #expect(questions[0].text == "What's your earliest memory?")

        #expect(questions[2].id == "A3")
        #expect(questions[2].answered == true)
    }

    @Test("Parse questions from full question bank format")
    func parseFullQuestionBank() {
        // Inline the actual question bank format to avoid test-bundle resource issues
        let fullMarkdown = """
        ## A: Origins (Childhood & Family)
        - [ ] A1: What's your earliest memory?
        - [ ] A2: Tell me about where you grew up.
        - [ ] A3: What was your family's financial situation?
        - [ ] A4: Tell me about a time you moved.
        - [ ] A5: What did your parents teach you without meaning to?

        ## B: Becoming (Growing Up & Finding Direction)
        - [ ] B1: When did you first feel like you had agency?
        - [ ] B2: Tell me about your first job.
        - [ ] B3: Was there a person who changed your trajectory?
        - [ ] B4: What was the first big risk you took?
        - [ ] B5: What's something you believed strongly that you no longer believe?

        ## C: Relationships & People
        - [ ] C1: Who believed in you before you believed in yourself?
        - [ ] C2: Tell me about a friendship that shaped who you are.
        - [ ] C3: How did your upbringing affect how you build relationships?
        - [ ] C4: Tell me about someone you lost.
        - [ ] C5: Who do you call when everything falls apart?

        ## D: Purpose & Calling
        - [ ] D1: What moment made you decide to pursue your path?
        - [ ] D2: What were you doing before you found your calling?
        - [ ] D3: Tell me about the first conversation where your path took shape.
        - [ ] D4: What did people say when you told them your plan?
        - [ ] D5: What keeps you going when it gets hard?

        ## E: Reflection & Wisdom
        - [ ] E1: What's the most important lesson your life has taught you?
        - [ ] E2: What would you tell your 18-year-old self?
        - [ ] E3: How has your definition of success changed over time?
        - [ ] E4: What are you most proud of that has nothing to do with work?
        - [ ] E5: What do you want the people you love to know about your life?
        """

        let questions = QuestionBankParser.parseQuestions(from: fullMarkdown)
        #expect(questions.count == 25) // 5 categories x 5 questions
        #expect(questions.allSatisfy { !$0.answered })

        let categories = QuestionBankParser.parseCategories(from: fullMarkdown)
        #expect(categories.count == 5)
        #expect(Set(categories.keys) == Set(["A", "B", "C", "D", "E"] as [Character]))
    }

    @Test("Mark answered adds date and checks box")
    func markAnswered() {
        let result = QuestionBankParser.markAnswered(questionID: "A1", in: sampleMarkdown)
        #expect(result != nil)
        #expect(result!.contains("- [x] A1: What's your earliest memory?"))
        #expect(result!.contains("*("))
    }

    @Test("Mark answered returns nil for already-answered question")
    func markAnsweredAlready() {
        let result = QuestionBankParser.markAnswered(questionID: "A3", in: sampleMarkdown)
        #expect(result == nil)
    }

    @Test("Mark answered returns nil for non-existent question")
    func markAnsweredNotFound() {
        let result = QuestionBankParser.markAnswered(questionID: "Z99", in: sampleMarkdown)
        #expect(result == nil)
    }

    @Test("Compute coverage calculates correct ratios")
    func computeCoverage() {
        let questions = QuestionBankParser.parseQuestions(from: sampleMarkdown)
        let categories = QuestionBankParser.parseCategories(from: sampleMarkdown)
        let coverage = QuestionBankParser.computeCoverage(questions: questions, categories: categories)

        // A: 1/3 answered = 33% -> yellow
        #expect(coverage["A"]?.total == 3)
        #expect(coverage["A"]?.answered == 1)
        #expect(coverage["A"]?.status == .yellow)

        // B: 1/2 answered = 50% -> yellow
        #expect(coverage["B"]?.total == 2)
        #expect(coverage["B"]?.answered == 1)
        #expect(coverage["B"]?.status == .yellow)

        // F: 0/1 -> red
        #expect(coverage["F"]?.total == 1)
        #expect(coverage["F"]?.answered == 0)
        #expect(coverage["F"]?.status == .red)

        // K: 0/1 -> red
        #expect(coverage["K"]?.status == .red)
    }

    @Test("Coverage thresholds at boundaries")
    func coverageThresholds() {
        // red: 0-30%
        let red = CoverageInfo(total: 10, answered: 2)
        #expect(red.status == .red)

        // yellow boundary: exactly 30%
        let yellow = CoverageInfo(total: 10, answered: 3)
        #expect(yellow.status == .yellow)

        // green boundary: exactly 70%
        let green = CoverageInfo(total: 10, answered: 7)
        #expect(green.status == .green)
    }
}

// Helper to find the test bundle
private class BundleToken {}
