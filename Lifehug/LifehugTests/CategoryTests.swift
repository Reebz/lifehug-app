import Testing
@testable import Lifehug

@Suite("Category Model")
struct CategoryTests {

    @Test("Main group for letters A through E")
    func mainGroupLetters() {
        for letter: Character in ["A", "B", "C", "D", "E"] {
            #expect(Category.groupForLetter(letter) == .main)
        }
    }

    @Test("Project group for letters F through J")
    func projectGroupLetters() {
        for letter: Character in ["F", "G", "H", "I", "J"] {
            #expect(Category.groupForLetter(letter) == .project)
        }
    }

    @Test("Spotlight group for letters K and beyond")
    func spotlightGroupLetters() {
        for letter: Character in ["K", "L", "M", "Z"] {
            #expect(Category.groupForLetter(letter) == .spotlight)
        }
    }

    @Test("CoverageInfo ratio computes correctly and handles zero total")
    func coverageRatio() {
        let full = CoverageInfo(total: 10, answered: 7)
        #expect(full.ratio == 0.7)

        let half = CoverageInfo(total: 4, answered: 2)
        #expect(half.ratio == 0.5)

        let empty = CoverageInfo(total: 0, answered: 0)
        #expect(empty.ratio == 0)
    }

    @Test("CoverageStatus boundaries: red < 0.3, yellow < 0.7, green >= 0.7")
    func coverageStatusBoundaries() {
        let red = CoverageInfo(total: 10, answered: 2)
        #expect(red.status == .red)

        let justBelowYellow = CoverageInfo(total: 100, answered: 29)
        #expect(justBelowYellow.status == .red)

        let exactlyYellow = CoverageInfo(total: 10, answered: 3)
        #expect(exactlyYellow.status == .yellow)

        let midYellow = CoverageInfo(total: 10, answered: 5)
        #expect(midYellow.status == .yellow)

        let justBelowGreen = CoverageInfo(total: 100, answered: 69)
        #expect(justBelowGreen.status == .yellow)

        let exactlyGreen = CoverageInfo(total: 10, answered: 7)
        #expect(exactlyGreen.status == .green)

        let fullGreen = CoverageInfo(total: 10, answered: 10)
        #expect(fullGreen.status == .green)
    }
}
