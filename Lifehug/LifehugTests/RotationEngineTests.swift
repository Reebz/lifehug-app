import Testing
@testable import Lifehug

@Suite("RotationEngine")
struct RotationEngineTests {

    let categories: [Character: Category] = [
        "A": Category(id: "A", name: "Origins", group: .main),
        "B": Category(id: "B", name: "Becoming", group: .main),
        "F": Category(id: "F", name: "The Problem", group: .project),
        "K": Category(id: "K", name: "Spotlight on Dad", group: .spotlight),
    ]

    func makeQuestion(_ id: String, answered: Bool = false) -> Question {
        Question(id: id, category: id.first!, text: "Q \(id)", answered: answered)
    }

    @Test("Picks lowest-coverage category first")
    func lowestCoverage() {
        let questions = [
            makeQuestion("A1", answered: true),
            makeQuestion("A2"),
            makeQuestion("B1"),
            makeQuestion("B2"),
            makeQuestion("F1"),
        ]
        let rotation = RotationState()

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        // B and F have 0% answered, A has 50%. Should pick from B or F.
        #expect(picked != nil)
        #expect(picked!.category != "A")
    }

    @Test("Alternates between main and project groups")
    func groupAlternation() {
        let questions = [
            makeQuestion("A1"),
            makeQuestion("F1"),
        ]
        // Last question was from main group (A)
        var rotation = RotationState()
        rotation.lastQuestionID = "A1"

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        // Should prefer project group (F) since last was main (A)
        #expect(picked?.id == "F1")
    }

    @Test("Alternates back to main from project")
    func groupAlternationReverse() {
        let questions = [
            makeQuestion("A1"),
            makeQuestion("F1"),
        ]
        var rotation = RotationState()
        rotation.lastQuestionID = "F1"

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        #expect(picked?.id == "A1")
    }

    @Test("Spotlight interleaving at configured frequency")
    func spotlightInterleaving() {
        let questions = [
            makeQuestion("A1"),
            makeQuestion("K1"),
        ]
        var rotation = RotationState()
        rotation.spotlightFrequency = 4
        rotation.questionsAsked = 4 // 4th question = spotlight turn

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        #expect(picked?.id == "K1")
    }

    @Test("No spotlight on non-spotlight turn")
    func noSpotlightWhenNotTurn() {
        let questions = [
            makeQuestion("A1"),
            makeQuestion("K1"),
        ]
        var rotation = RotationState()
        rotation.spotlightFrequency = 4
        rotation.questionsAsked = 3 // Not a spotlight turn

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        #expect(picked?.id == "A1")
    }

    @Test("Returns nil when all questions answered")
    func allAnswered() {
        let questions = [
            makeQuestion("A1", answered: true),
            makeQuestion("B1", answered: true),
        ]
        let rotation = RotationState()

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        #expect(picked == nil)
    }

    @Test("Picks first pending in document order within category")
    func documentOrder() {
        let questions = [
            makeQuestion("A1", answered: true),
            makeQuestion("A2"),
            makeQuestion("A3"),
        ]
        let categoriesSmall: [Character: Category] = [
            "A": Category(id: "A", name: "Origins", group: .main),
        ]
        let rotation = RotationState()

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categoriesSmall,
            rotation: rotation
        )

        #expect(picked?.id == "A2")
    }

    @Test("Falls back to first pending if no preferred group available")
    func fallbackNoCategoryMatch() {
        let questions = [
            makeQuestion("A1"),
        ]
        var rotation = RotationState()
        rotation.lastQuestionID = "A2" // last was main, prefers project, but no project questions

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categories,
            rotation: rotation
        )

        #expect(picked?.id == "A1")
    }

    @Test("Spotlight turn falls back to main when no spotlight questions")
    func spotlightFallback() {
        let questions = [
            makeQuestion("A1"),
            makeQuestion("F1"),
        ]
        let categoriesNoSpotlight: [Character: Category] = [
            "A": Category(id: "A", name: "Origins", group: .main),
            "F": Category(id: "F", name: "Problem", group: .project),
        ]
        var rotation = RotationState()
        rotation.spotlightFrequency = 4
        rotation.questionsAsked = 4

        let picked = RotationEngine.pickNextQuestion(
            questions: questions,
            categories: categoriesNoSpotlight,
            rotation: rotation
        )

        #expect(picked != nil)
        #expect(picked!.category != "K")
    }

    @Test("Mark answered updates markdown and rotation state")
    func markAnswered() {
        let markdown = "- [ ] A1: What's your earliest memory?"
        let rotation = RotationState()

        let result = RotationEngine.markAnswered(
            questionID: "A1",
            markdown: markdown,
            rotation: rotation
        )

        #expect(result != nil)
        #expect(result!.updatedMarkdown.contains("[x]"))
        #expect(result!.updatedRotation.lastQuestionID == "A1")
        #expect(result!.updatedRotation.questionsAsked == 1)
    }
}
