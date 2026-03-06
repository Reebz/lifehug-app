import Foundation

struct UserConfig: Codable {
    var name: String = "friend"
    var projects: [Project] = []

    struct Project: Codable, Identifiable {
        var id: String { name }
        let name: String
        let type: String
    }
}
