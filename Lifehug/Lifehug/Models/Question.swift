import Foundation

struct Question: Codable, Identifiable {
    let id: String       // e.g. "A1"
    let category: Character
    let text: String
    var answered: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, answered
    }

    var categoryString: String {
        String(category)
    }

    init(id: String, category: Character, text: String, answered: Bool) {
        self.id = id
        self.category = category
        self.text = text
        self.answered = answered
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        answered = try container.decode(Bool.self, forKey: .answered)
        guard let first = id.first else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Empty question ID")
        }
        category = first
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(answered, forKey: .answered)
    }
}
