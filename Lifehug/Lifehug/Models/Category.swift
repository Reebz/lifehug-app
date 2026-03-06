import Foundation

struct Category: Identifiable {
    let id: Character
    let name: String
    let group: Group

    enum Group: String, Codable {
        case main
        case project
        case spotlight
    }

    static func groupForLetter(_ letter: Character) -> Group {
        switch letter {
        case "A"..."E":
            return .main
        case "F"..."J":
            return .project
        default:
            return .spotlight
        }
    }
}

struct CoverageInfo {
    let total: Int
    let answered: Int

    var ratio: Double {
        total > 0 ? Double(answered) / Double(total) : 0
    }

    var status: CoverageStatus {
        if ratio >= 0.7 { return .green }
        if ratio >= 0.3 { return .yellow }
        return .red
    }
}

enum CoverageStatus: String {
    case red
    case yellow
    case green
}
