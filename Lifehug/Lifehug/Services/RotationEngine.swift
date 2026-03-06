import Foundation

struct RotationEngine {

    /// Pick the next question using rotation logic. Faithful port of ask.py's pick_next_question().
    ///
    /// Algorithm:
    /// 1. Filter to unanswered questions
    /// 2. Check if it's a spotlight turn (questions_asked % spotlight_frequency == 0)
    /// 3. Compute answered ratio per category, sort ascending (lowest coverage = highest priority)
    /// 4. Separate spotlight vs non-spotlight categories
    /// 5. If spotlight turn + spotlight questions exist: pick lowest-coverage spotlight category
    /// 6. Otherwise: alternate between main/project groups based on last_question_id
    /// 7. Within chosen category: pick first pending question in document order
    /// 8. Fallback: first pending question overall
    static func pickNextQuestion(
        questions: [Question],
        categories: [Character: Category],
        rotation: RotationState
    ) -> Question? {
        let pending = questions.filter { !$0.answered }
        guard !pending.isEmpty else { return nil }

        let spotlightFreq = rotation.spotlightFrequency
        let questionsAsked = rotation.questionsAsked

        // Check if it's time for a spotlight question
        let spotlightTurn = spotlightFreq > 0
            && questionsAsked > 0
            && questionsAsked % spotlightFreq == 0

        // Count answered per category
        var answeredPerCat: [Character: Int] = [:]
        var totalPerCat: [Character: Int] = [:]
        for q in questions {
            totalPerCat[q.category, default: 0] += 1
            if q.answered {
                answeredPerCat[q.category, default: 0] += 1
            }
        }

        // Score: ratio of answered (lower = higher priority)
        let pendingCats = Set(pending.map(\.category))
        var catScores: [(ratio: Double, category: Character)] = []
        for cat in pendingCats {
            let ratio = Double(answeredPerCat[cat, default: 0]) / Double(totalPerCat[cat, default: 1])
            catScores.append((ratio, cat))
        }
        catScores.sort { $0.ratio < $1.ratio }

        // Separate spotlight and non-spotlight categories
        let spotlightCats = catScores.filter { categories[$0.category]?.group == .spotlight }
        let mainCats = catScores.filter { categories[$0.category]?.group != .spotlight }

        let chosenCat: Character

        // If spotlight turn and there are spotlight questions pending
        if spotlightTurn && !spotlightCats.isEmpty {
            chosenCat = spotlightCats[0].category
        } else if !mainCats.isEmpty {
            // Alternate between groups based on last question
            let lastGroup: Category.Group?
            if let lastID = rotation.lastQuestionID, let lastCatChar = lastID.first {
                lastGroup = categories[lastCatChar]?.group
            } else {
                lastGroup = nil
            }

            // Try to alternate between main and project groups
            let preferredGroup: Category.Group?
            switch lastGroup {
            case .main:
                preferredGroup = .project
            case .project:
                preferredGroup = .main
            default:
                preferredGroup = nil
            }

            var found: Character?
            if let preferredGroup {
                for (_, cat) in mainCats {
                    if categories[cat]?.group == preferredGroup {
                        found = cat
                        break
                    }
                }
            }

            chosenCat = found ?? mainCats[0].category
        } else {
            chosenCat = catScores[0].category
        }

        // Pick first pending in chosen category (document order)
        for q in pending where q.category == chosenCat {
            return q
        }

        // Fallback: first pending question overall
        return pending.first
    }

    /// Mark a question as answered: updates question bank markdown and rotation state.
    static func markAnswered(
        questionID: String,
        markdown: String,
        rotation: RotationState
    ) -> (updatedMarkdown: String, updatedRotation: RotationState)? {
        guard let updatedMarkdown = QuestionBankParser.markAnswered(questionID: questionID, in: markdown) else {
            return nil
        }

        var updatedRotation = rotation
        updatedRotation.lastQuestionID = questionID
        updatedRotation.lastAskedAt = ISO8601DateFormatter().string(from: Date())
        updatedRotation.questionsAsked = rotation.questionsAsked + 1

        return (updatedMarkdown, updatedRotation)
    }
}
