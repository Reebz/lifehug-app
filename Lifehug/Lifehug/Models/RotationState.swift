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

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        currentPass = try container.decodeIfPresent(Int.self, forKey: .currentPass)
        passNames = try container.decodeIfPresent([String].self, forKey: .passNames)
        lastQuestionID = try container.decodeIfPresent(String.self, forKey: .lastQuestionID)
        lastAskedAt = try container.decodeIfPresent(String.self, forKey: .lastAskedAt)
        questionsAsked = try container.decodeIfPresent(Int.self, forKey: .questionsAsked) ?? 0
        questionsAnswered = try container.decodeIfPresent(Int.self, forKey: .questionsAnswered)
        nextQuestionID = try container.decodeIfPresent(String.self, forKey: .nextQuestionID)
        spotlightFrequency = try container.decodeIfPresent(Int.self, forKey: .spotlightFrequency) ?? 4
    }
}
