import Foundation

struct Answer {
    let questionID: String
    let questionText: String
    let categoryLetter: Character
    let categoryName: String
    let passNumber: Int
    let askedDate: Date
    let answeredDate: Date
    let answerText: String
    let followUpQuestions: [FollowUpQuestion]
    let source: AnswerSource

    enum AnswerSource {
        case text
        case voice
    }

    struct FollowUpQuestion {
        let id: String
        let text: String
    }

    func toMarkdown() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var md = """
        # Question \(questionID): \(questionText)
        **Category:** \(categoryLetter) (\(categoryName)) | **Pass:** \(passNumber)
        **Asked:** \(dateFormatter.string(from: askedDate)) | **Answered:** \(dateFormatter.string(from: answeredDate))

        ---

        \(answerText)

        ---

        """

        if !followUpQuestions.isEmpty {
            md += "\n## Follow-up Questions Generated\n"
            for fq in followUpQuestions {
                md += "- \(fq.id): \"\(fq.text)\"\n"
            }
        }

        if source == .voice {
            md += "\n**Source:** voice message (transcribed)\n"
        }

        return md
    }

    static func fromMarkdown(_ text: String) -> Answer? {
        let lines = text.components(separatedBy: "\n")

        // Need at least 3 lines: header, metadata, dates
        guard lines.count >= 3 else { return nil }

        // Parse header: # Question A1: What's your earliest memory?
        guard let headerLine = lines.first,
              let headerMatch = headerLine.firstMatch(of: /^# Question ([A-Z]\d+): (.+)$/) else {
            return nil
        }
        let questionID = String(headerMatch.1)
        let questionText = String(headerMatch.2)
        guard let categoryLetter = questionID.first else { return nil }

        // Parse metadata: **Category:** A (Origins) | **Pass:** 1
        let categoryName: String
        let passNumber: Int
        if lines.count > 1,
           let catMatch = lines[1].firstMatch(of: /\*\*Category:\*\* [A-Z] \((.+?)\) \| \*\*Pass:\*\* (\d+)/) {
            categoryName = String(catMatch.1)
            passNumber = Int(catMatch.2) ?? 1
        } else {
            categoryName = ""
            passNumber = 1
        }

        // Parse dates: **Asked:** 2026-03-01 | **Answered:** 2026-03-01
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let askedDate: Date
        let answeredDate: Date
        if lines.count > 2,
           let dateMatch = lines[2].firstMatch(of: /\*\*Asked:\*\* (\d{4}-\d{2}-\d{2}) \| \*\*Answered:\*\* (\d{4}-\d{2}-\d{2})/) {
            askedDate = dateFormatter.date(from: String(dateMatch.1)) ?? Date()
            answeredDate = dateFormatter.date(from: String(dateMatch.2)) ?? Date()
        } else {
            askedDate = Date()
            answeredDate = Date()
        }

        // Parse answer text between --- markers
        var answerLines: [String] = []
        var inAnswer = false
        var separatorCount = 0
        let contentLines = lines.count > 3 ? Array(lines.dropFirst(3)) : []
        for line in contentLines {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                separatorCount += 1
                if separatorCount == 1 {
                    inAnswer = true
                    continue
                } else if separatorCount == 2 {
                    break
                }
            }
            if inAnswer {
                answerLines.append(line)
            }
        }
        let answerText = answerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse follow-up questions
        var followUps: [FollowUpQuestion] = []
        var inFollowUps = false
        for line in lines {
            if line.contains("## Follow-up Questions Generated") {
                inFollowUps = true
                continue
            }
            if inFollowUps, let match = line.firstMatch(of: /^- ([A-Z]\d+): "(.+)"$/) {
                followUps.append(FollowUpQuestion(id: String(match.1), text: String(match.2)))
            }
        }

        let source: AnswerSource = text.contains("**Source:** voice message") ? .voice : .text

        return Answer(
            questionID: questionID,
            questionText: questionText,
            categoryLetter: categoryLetter,
            categoryName: categoryName,
            passNumber: passNumber,
            askedDate: askedDate,
            answeredDate: answeredDate,
            answerText: answerText,
            followUpQuestions: followUps,
            source: source
        )
    }
}
