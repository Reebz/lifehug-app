import Testing
import Foundation
@testable import Lifehug

@Suite("OnboardingTemplates")
struct OnboardingTemplatesTests {

    @Test("Memoir categories count matches expected")
    func memoirCategoriesCount() {
        let cats = OnboardingTemplates.categories(for: "Memoir")
        #expect(cats.count == 3) // F: Career & Work, G: Travel, H: Health
    }

    @Test("Founder Story categories count matches expected")
    func founderStoryCategoriesCount() {
        let cats = OnboardingTemplates.categories(for: "Founder Story")
        #expect(cats.count == 4) // F: Problem, G: Building, H: Hard Parts, I: Vision
    }

    @Test("Unknown project type falls back to memoir categories")
    func unknownTypeFallback() {
        let unknown = OnboardingTemplates.categories(for: "Underwater Basket Weaving")
        let memoir = OnboardingTemplates.categories(for: "Memoir")

        #expect(unknown.count == memoir.count)
        for (u, m) in zip(unknown, memoir) {
            #expect(u.letter == m.letter)
            #expect(u.name == m.name)
        }
    }

    @Test("markdownSections produces valid format with headers and unchecked items")
    func markdownSectionsValidFormat() {
        let md = OnboardingTemplates.markdownSections(for: "Memoir")

        // Contains ## headers
        #expect(md.contains("## F: Career & Work"))
        #expect(md.contains("## G: Travel & Adventure"))
        #expect(md.contains("## H: Health & Growth"))

        // Contains unchecked question lines
        #expect(md.contains("- [ ] F1:"))
        #expect(md.contains("- [ ] G1:"))
        #expect(md.contains("- [ ] H1:"))
    }

    @Test("All questions in markdown output are unanswered")
    func allQuestionsUnanswered() {
        let md = OnboardingTemplates.markdownSections(for: "Founder Story")

        // No checked boxes should exist
        #expect(!md.contains("[x]"))

        // Every question line should have an unchecked box
        let questionLines = md.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
        #expect(!questionLines.isEmpty)
        for line in questionLines {
            #expect(line.contains("- [ ]"))
        }
    }

    @Test("All project types in the list produce categories")
    func allProjectTypesHaveCategories() {
        for projectType in OnboardingTemplates.projectTypes {
            let cats = OnboardingTemplates.categories(for: projectType)
            #expect(!cats.isEmpty, "Project type '\(projectType)' should have categories")
            // Every category should start at F or later (project range)
            for cat in cats {
                #expect(cat.letter >= "F", "Category letter should be F or later, got \(cat.letter)")
            }
            // Every category should have at least one question
            for cat in cats {
                #expect(!cat.questions.isEmpty, "\(cat.name) should have questions")
            }
        }
    }
}
