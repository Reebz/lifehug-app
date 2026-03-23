import Foundation

struct UserConfig: Codable {
    var name: String = "friend"
    var projects: [Project] = []

    struct Project: Codable, Identifiable {
        var id: String { name }
        let name: String
        let type: String
    }

    init(name: String = "friend", projects: [Project] = []) {
        self.name = name
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "friend"
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }
}
