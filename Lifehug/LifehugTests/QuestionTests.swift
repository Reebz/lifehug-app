import Testing
import Foundation
@testable import Lifehug

@Suite("Question Model")
struct QuestionTests {

    @Test("Encode/decode roundtrip preserves all fields")
    func roundtrip() throws {
        let original = Question(id: "B3", category: "B", text: "When did you first feel independent?", answered: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Question.self, from: data)

        #expect(decoded.id == "B3")
        #expect(decoded.category == "B")
        #expect(decoded.text == "When did you first feel independent?")
        #expect(decoded.answered == true)
    }

    @Test("Category derived from first character of ID on decode")
    func categoryDerivation() throws {
        let json = """
        {"id": "F7", "text": "What problem were you solving?", "answered": false}
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(Question.self, from: json)

        #expect(question.category == "F")
        #expect(question.id == "F7")
    }

    @Test("Empty ID throws DecodingError")
    func emptyIDThrows() {
        let json = """
        {"id": "", "text": "No ID question", "answered": false}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Question.self, from: json)
        }
    }

    @Test("categoryString returns single-character String")
    func categoryString() {
        let question = Question(id: "K2", category: "K", text: "Tell me about Dad.", answered: false)

        #expect(question.categoryString == "K")
        #expect(question.categoryString.count == 1)
    }

    @Test("Encode omits category from JSON output")
    func encodeOmitsCategory() throws {
        let question = Question(id: "A1", category: "A", text: "Earliest memory?", answered: false)

        let data = try JSONEncoder().encode(question)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["category"] == nil)
        #expect(dict["id"] as? String == "A1")
        #expect(dict["text"] as? String == "Earliest memory?")
        #expect(dict["answered"] as? Bool == false)
    }
}
