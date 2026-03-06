import Foundation

struct RotationState: Codable {
    var version: Int = 1
    var currentPass: Int?
    var passNames: [String]?
    var lastQuestionID: String?
    var lastAskedAt: String?
    var questionsAsked: Int = 0
    var questionsAnswered: Int?
    var nextQuestionID: String?
    var spotlightFrequency: Int = 4

    enum CodingKeys: String, CodingKey {
        case version
        case currentPass = "current_pass"
        case passNames = "pass_names"
        case lastQuestionID = "last_question_id"
        case lastAskedAt = "last_asked_at"
        case questionsAsked = "questions_asked"
        case questionsAnswered = "questions_answered"
        case nextQuestionID = "next_question_id"
        case spotlightFrequency = "spotlight_frequency"
    }

    static let `default` = RotationState()
}
