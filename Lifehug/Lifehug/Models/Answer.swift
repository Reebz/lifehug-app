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
    /// Ordered per-turn segments (KTD6): the audio-linked index over the answer. Absent for
    /// pre-feature answers (lenient parse defaults to `[]`); the whole-answer `source` above
    /// stays for compatibility, but per-segment `source` is authoritative for affordances.
    var segments: [Segment] = []

    enum AnswerSource {
        case text
        case voice
    }

    /// One spoken or typed turn. `text` is the segment's original transcript/typed text (the
    /// facing-page and provenance source); the editable answer body lives in `answerText`.
    struct Segment: Equatable {
        var text: String
        var clipFilename: String?          // committed clip name, or nil (typed / capture failed)
        var source: SegmentSource
        var isEdited: Bool = false         // body text diverged from this original (KTD8)
        var needsTranscription: Bool = false  // audio kept but transcript empty/failed (R3)

        enum SegmentSource: String {
            case voice
            case text
        }
    }

    struct FollowUpQuestion {
        let id: String
        let text: String
    }

    /// A copy with a replaced segment list (all other fields intact). Used by the edit path
    /// and launch reconciliation to rewrite segments without touching the rest of the answer.
    func replacingSegments(_ newSegments: [Segment]) -> Answer {
        Answer(
            questionID: questionID, questionText: questionText, categoryLetter: categoryLetter,
            categoryName: categoryName, passNumber: passNumber, askedDate: askedDate,
            answeredDate: answeredDate, answerText: answerText, followUpQuestions: followUpQuestions,
            source: source, segments: newSegments
        )
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

        // Voice Clips index (KTD6): written only when audio is involved, so pre-feature and
        // purely-typed answers stay unchanged. One line per segment, text escaped so a
        // multi-line turn still occupies exactly one line. This section comes last (after
        // the second `---`), so old readers and the body parser ignore it.
        if segments.contains(where: { $0.source == .voice || $0.clipFilename != nil }) {
            md += "\n## Voice Clips\n"
            for seg in segments {
                let clip = seg.clipFilename ?? "none"
                md += "- [\(seg.source.rawValue)] clip=\(clip) edited=\(seg.isEdited ? 1 : 0) needs=\(seg.needsTranscription ? 1 : 0) :: \(Self.escapeSegmentText(seg.text))\n"
            }
        }

        return md
    }

    /// Escape a segment's text to a single line: backslash first, then newlines.
    private static func escapeSegmentText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Inverse of `escapeSegmentText` — a left-to-right unescape so `\\` and `\n` don't
    /// interfere (a naive two-pass replace would mangle a literal backslash-n).
    private static func unescapeSegmentText(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { result.append(c); continue }
            switch iterator.next() {
            case "n": result.append("\n")
            case "\\": result.append("\\")
            case let other?: result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }

    private static func parseSegmentLine(_ line: String) -> Segment? {
        guard let m = line.firstMatch(
            of: /^- \[(voice|text)\] clip=(\S+) edited=([01]) needs=([01]) :: (.*)$/
        ) else { return nil }
        let source: Segment.SegmentSource = m.1 == "voice" ? .voice : .text
        let clip = String(m.2) == "none" ? nil : String(m.2)
        return Segment(
            text: unescapeSegmentText(String(m.5)),
            clipFilename: clip,
            source: source,
            isEdited: m.3 == "1",
            needsTranscription: m.4 == "1"
        )
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

        // Parse the answer body, written raw between two "---" separators. The body may
        // itself contain a line equal to "---" (a Markdown horizontal rule), so stopping at
        // the first interior separator would drop the rest of the body on read, and then on
        // the next save. The closing separator is the last "---" before the trailing sections
        // (Follow-up Questions, Source, Voice Clips). Bounding the search to that region means
        // a stray "---" a desktop editor or a hand-edit left inside a trailing section is never
        // mistaken for the closing rule. Read-side only: the written format is unchanged, so
        // existing files and the desktop tool stay compatible.
        let contentLines = lines.count > 3 ? Array(lines.dropFirst(3)) : []
        func startsTrailingSection(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "## Follow-up Questions Generated"
                || trimmed == "## Voice Clips"
                || trimmed.hasPrefix("**Source:** voice message")
        }
        let bodyLimit = contentLines.firstIndex(where: startsTrailingSection) ?? contentLines.count
        let separatorIndices = (0..<bodyLimit).filter {
            contentLines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }
        let bodyRange: Range<Int>?
        if let open = separatorIndices.first, let close = separatorIndices.last, close > open {
            bodyRange = (open + 1)..<close
        } else if let open = separatorIndices.first {
            // Only one separator (malformed/truncated file): take everything up to the trailing
            // sections as the body.
            bodyRange = (open + 1)..<bodyLimit
        } else {
            bodyRange = nil
        }
        let answerText: String
        if let bodyRange {
            answerText = contentLines[bodyRange].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            answerText = ""
        }

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

        // Parse the Voice Clips index. Absent in pre-feature files → empty segments (KTD6).
        var segments: [Segment] = []
        var inClips = false
        for line in lines {
            // Exact header match: a segment's own text could contain "## Voice Clips".
            if line.trimmingCharacters(in: .whitespaces) == "## Voice Clips" { inClips = true; continue }
            if inClips, let seg = parseSegmentLine(line) { segments.append(seg) }
        }

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
            source: source,
            segments: segments
        )
    }
}
