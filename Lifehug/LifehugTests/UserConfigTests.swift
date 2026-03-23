import Testing
import Foundation
@testable import Lifehug

@Suite("UserConfig Model")
struct UserConfigTests {

    @Test("Encode/decode roundtrip preserves all fields")
    func roundtrip() throws {
        let config = UserConfig(
            name: "Mitch",
            projects: [
                UserConfig.Project(name: "Memoir", type: "memoir"),
                UserConfig.Project(name: "Company Story", type: "founder"),
            ]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(UserConfig.self, from: data)

        #expect(decoded.name == "Mitch")
        #expect(decoded.projects.count == 2)
        #expect(decoded.projects[0].name == "Memoir")
        #expect(decoded.projects[0].type == "memoir")
        #expect(decoded.projects[1].name == "Company Story")
        #expect(decoded.projects[1].type == "founder")
    }

    @Test("Default values are correct")
    func defaults() {
        let config = UserConfig()

        #expect(config.name == "friend")
        #expect(config.projects.isEmpty)
    }

    @Test("Project conforms to Identifiable using name as id")
    func projectIdentifiable() {
        let project = UserConfig.Project(name: "Family History", type: "family")

        #expect(project.id == "Family History")
        #expect(project.id == project.name)
    }

    @Test("Empty JSON decodes with defaults")
    func emptyJSON() throws {
        let json = "{}".data(using: .utf8)!

        let config = try JSONDecoder().decode(UserConfig.self, from: json)

        #expect(config.name == "friend")
        #expect(config.projects.isEmpty)
    }
}
