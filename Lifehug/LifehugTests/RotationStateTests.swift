import Testing
import Foundation
@testable import Lifehug

@Suite("RotationState Model")
struct RotationStateTests {

    @Test("Encode/decode roundtrip preserves all fields")
    func roundtrip() throws {
        var state = RotationState()
        state.currentPass = 2
        state.passNames = ["skeleton", "depth", "connections", "polish"]
        state.lastQuestionID = "B3"
        state.lastAskedAt = "2026-03-20T09:00:00"
        state.questionsAsked = 15
        state.questionsAnswered = 12
        state.nextQuestionID = "C1"
        state.spotlightFrequency = 5

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RotationState.self, from: data)

        #expect(decoded.version == 1)
        #expect(decoded.currentPass == 2)
        #expect(decoded.passNames == ["skeleton", "depth", "connections", "polish"])
        #expect(decoded.lastQuestionID == "B3")
        #expect(decoded.lastAskedAt == "2026-03-20T09:00:00")
        #expect(decoded.questionsAsked == 15)
        #expect(decoded.questionsAnswered == 12)
        #expect(decoded.nextQuestionID == "C1")
        #expect(decoded.spotlightFrequency == 5)
    }

    @Test("Decodes snake_case keys from JSON")
    func snakeCaseDecode() throws {
        let json = """
        {
            "version": 1,
            "current_pass": 3,
            "pass_names": ["skeleton", "depth"],
            "last_question_id": "A5",
            "last_asked_at": "2026-03-15T10:00:00",
            "questions_asked": 10,
            "questions_answered": 8,
            "next_question_id": "B2",
            "spotlight_frequency": 6
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(RotationState.self, from: json)

        #expect(state.currentPass == 3)
        #expect(state.passNames == ["skeleton", "depth"])
        #expect(state.lastQuestionID == "A5")
        #expect(state.lastAskedAt == "2026-03-15T10:00:00")
        #expect(state.questionsAsked == 10)
        #expect(state.questionsAnswered == 8)
        #expect(state.nextQuestionID == "B2")
        #expect(state.spotlightFrequency == 6)
    }

    @Test("Default values are correct")
    func defaults() {
        let state = RotationState.default

        #expect(state.version == 1)
        #expect(state.currentPass == nil)
        #expect(state.passNames == nil)
        #expect(state.lastQuestionID == nil)
        #expect(state.lastAskedAt == nil)
        #expect(state.questionsAsked == 0)
        #expect(state.questionsAnswered == nil)
        #expect(state.nextQuestionID == nil)
        #expect(state.spotlightFrequency == 4)
    }

    @Test("Partial JSON uses defaults for missing fields")
    func partialJSON() throws {
        let json = """
        {"version": 1, "questions_asked": 5}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(RotationState.self, from: json)

        #expect(state.version == 1)
        #expect(state.questionsAsked == 5)
        #expect(state.currentPass == nil)
        #expect(state.lastQuestionID == nil)
        #expect(state.spotlightFrequency == 4)
    }

    @Test("Encodes to snake_case keys")
    func snakeCaseEncode() throws {
        var state = RotationState()
        state.lastQuestionID = "D1"
        state.questionsAsked = 7
        state.spotlightFrequency = 3

        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["last_question_id"] as? String == "D1")
        #expect(dict["questions_asked"] as? Int == 7)
        #expect(dict["spotlight_frequency"] as? Int == 3)
        // Verify camelCase keys are absent
        #expect(dict["lastQuestionID"] == nil)
        #expect(dict["questionsAsked"] == nil)
        #expect(dict["spotlightFrequency"] == nil)
    }
}
