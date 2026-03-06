import Foundation

struct OnboardingTemplates {

    /// Project type options shown during onboarding.
    static let projectTypes = [
        "Memoir",
        "Founder Story",
        "Family History",
        "Creative Journey",
        "Career Story",
    ]

    /// Returns pre-written project categories (F-J) based on the selected project type.
    /// Each tuple contains a letter, category name, and a list of open-ended questions.
    static func categories(for projectType: String) -> [(letter: Character, name: String, questions: [String])] {
        switch projectType {
        case "Memoir":
            return memoirCategories
        case "Founder Story":
            return founderStoryCategories
        case "Family History":
            return familyHistoryCategories
        case "Creative Journey":
            return creativeJourneyCategories
        case "Career Story":
            return careerStoryCategories
        default:
            return memoirCategories
        }
    }

    /// Formats template categories as markdown sections to append to question-bank.md.
    static func markdownSections(for projectType: String) -> String {
        let cats = categories(for: projectType)
        var sections: [String] = []

        for cat in cats {
            var lines: [String] = []
            lines.append("## \(cat.letter): \(cat.name)")
            for (index, question) in cat.questions.enumerated() {
                lines.append("- [ ] \(cat.letter)\(index + 1): \(question)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Memoir

    private static let memoirCategories: [(letter: Character, name: String, questions: [String])] = [
        (
            letter: "F",
            name: "Career & Work",
            questions: [
                "Tell me about the moment you knew what you wanted to do for a living.",
                "What did your workspace look like at the job that mattered most to you?",
                "Describe a day at work that changed how you saw yourself professionally.",
                "What did it feel like the first time someone called you an expert at something?",
                "Tell me about a professional failure that taught you something you still carry.",
            ]
        ),
        (
            letter: "G",
            name: "Travel & Adventure",
            questions: [
                "What is the farthest from home you have ever been, and what pulled you there?",
                "Tell me about a place that smelled or sounded completely different from anything you knew.",
                "Describe a moment during a trip when you felt truly lost — physically or emotionally.",
                "What journey changed the way you think about where you come from?",
                "Tell me about a stranger you met while traveling whose face you can still picture.",
            ]
        ),
        (
            letter: "H",
            name: "Health & Growth",
            questions: [
                "Tell me about a time your body surprised you — for better or worse.",
                "What habit or practice changed the way you feel day to day?",
                "Describe a moment when you realized you needed to take better care of yourself.",
                "What did it feel like to recover from something you were not sure you could get through?",
                "Tell me about a conversation about health that was harder than you expected.",
            ]
        ),
    ]

    // MARK: - Founder Story

    private static let founderStoryCategories: [(letter: Character, name: String, questions: [String])] = [
        (
            letter: "F",
            name: "The Problem",
            questions: [
                "Tell me about the exact moment you first noticed the problem your company solves.",
                "What did it feel like to realize no one else was fixing this the way you imagined?",
                "Describe the person whose struggle made the problem feel urgent and personal to you.",
                "What were you doing in your life when the idea first started forming?",
                "Tell me about the conversation that made you think this could actually be a business.",
            ]
        ),
        (
            letter: "G",
            name: "Building",
            questions: [
                "What did the first version of your product look like, and what embarrasses you about it now?",
                "Tell me about the first person who used what you built. What was their reaction?",
                "Describe the workspace where you did your earliest building — what did it look like at midnight?",
                "What skill did you have to learn from scratch that you never expected to need?",
                "Tell me about a moment when something you built actually worked for the first time.",
            ]
        ),
        (
            letter: "H",
            name: "The Hard Parts",
            questions: [
                "Tell me about the closest you came to quitting. What was happening that week?",
                "Describe a conversation with a co-founder, investor, or teammate that still sits with you.",
                "What did it feel like to let someone go, or to lose someone who mattered to the company?",
                "Tell me about a moment when the money almost ran out. What did that feel like in your body?",
                "What sacrifice did building this company require that you did not expect?",
            ]
        ),
        (
            letter: "I",
            name: "Vision",
            questions: [
                "Tell me about the future you are building toward — what does the world look like if you succeed?",
                "What moment made you realize your vision was bigger than you originally thought?",
                "Describe the first time someone else articulated your vision back to you better than you could.",
                "What part of your original vision have you had to let go of, and what replaced it?",
                "Tell me about a quiet moment when you felt certain you were building the right thing.",
            ]
        ),
    ]

    // MARK: - Family History

    private static let familyHistoryCategories: [(letter: Character, name: String, questions: [String])] = [
        (
            letter: "F",
            name: "Grandparents",
            questions: [
                "Tell me about one of your grandparents — what did their hands look like?",
                "What story did a grandparent tell that you can still hear in their voice?",
                "Describe the place where your grandparents lived. What did it smell like when you walked in?",
                "What did your grandparents sacrifice that made your life possible?",
                "Tell me about a moment with a grandparent that you did not appreciate until much later.",
            ]
        ),
        (
            letter: "G",
            name: "Parents",
            questions: [
                "Tell me about something your parents argued about that taught you what they valued.",
                "What did your parents do for work, and how did it shape the household?",
                "Describe a moment when you saw your parent as a full human being, not just a parent.",
                "What is something your parents never talked about that you wish they had?",
                "Tell me about the way your parents showed love — even if it was not obvious at the time.",
            ]
        ),
        (
            letter: "H",
            name: "Traditions",
            questions: [
                "What family tradition do you still carry, and what does it mean to you now?",
                "Tell me about a holiday or gathering that captures your family at its most itself.",
                "What food connects you most strongly to where you come from?",
                "Describe a ritual or routine your family had that outsiders might find surprising.",
                "Tell me about a tradition that ended. What replaced it, if anything?",
            ]
        ),
        (
            letter: "I",
            name: "Migration & Moves",
            questions: [
                "Tell me about the biggest move your family ever made. What did they leave behind?",
                "What did it feel like to arrive somewhere completely new as a family?",
                "Describe an object your family brought from one place to another that carried meaning.",
                "What part of your family's origin story do you know least about, and why?",
                "Tell me about how the place your family came from shaped the way they see the world.",
            ]
        ),
    ]

    // MARK: - Creative Journey

    private static let creativeJourneyCategories: [(letter: Character, name: String, questions: [String])] = [
        (
            letter: "F",
            name: "Early Inspiration",
            questions: [
                "Tell me about the first piece of art, music, or writing that made you feel something you could not name.",
                "What did it feel like the first time you made something and someone else responded to it?",
                "Describe the room or space where you first started creating. What was around you?",
                "Who was the first person who made you believe you could be a creative person?",
                "Tell me about a moment in childhood when you lost track of time making something.",
            ]
        ),
        (
            letter: "G",
            name: "The Craft",
            questions: [
                "What part of your craft feels like breathing now that once felt impossible?",
                "Tell me about a teacher, mentor, or peer who changed the way you approach your work.",
                "Describe your creative process on a good day — what does the rhythm feel like?",
                "What tool or material do you have the deepest relationship with?",
                "Tell me about a technique or idea you struggled with for years before it clicked.",
            ]
        ),
        (
            letter: "H",
            name: "Breakthroughs",
            questions: [
                "Tell me about the piece of work that changed everything for you. What made it different?",
                "What did it feel like the first time your work reached an audience you did not expect?",
                "Describe a creative block that lasted long enough to scare you. How did you get through it?",
                "Tell me about a moment when you surprised yourself with what you were capable of.",
                "What project or piece are you most proud of, and what does it say about who you are?",
            ]
        ),
    ]

    // MARK: - Career Story

    private static let careerStoryCategories: [(letter: Character, name: String, questions: [String])] = [
        (
            letter: "F",
            name: "Getting Started",
            questions: [
                "Tell me about your very first day in your industry. What did you notice?",
                "What did it feel like to be the least experienced person in the room?",
                "Describe the first boss or leader who shaped how you think about work.",
                "What early mistake taught you the most about how your field actually works?",
                "Tell me about the moment you realized this career was going to be more than just a job.",
            ]
        ),
        (
            letter: "G",
            name: "Pivotal Moments",
            questions: [
                "Tell me about a decision that split your career into before and after.",
                "What opportunity almost passed you by? How did you catch it?",
                "Describe a meeting, call, or conversation that redirected your professional life.",
                "What did it feel like to bet on yourself when the outcome was uncertain?",
                "Tell me about a time you walked away from something secure. What pulled you forward?",
            ]
        ),
        (
            letter: "H",
            name: "Leadership",
            questions: [
                "Tell me about the first time you were responsible for someone else's career.",
                "What did it feel like to make a decision that affected people beyond yourself?",
                "Describe a moment when you realized your leadership style had changed.",
                "Tell me about a hard conversation you had as a leader that made things better.",
                "What lesson about leadership did you learn the hard way that you now pass on to others?",
            ]
        ),
    ]
}
