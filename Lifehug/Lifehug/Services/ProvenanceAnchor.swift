import Foundation
import CryptoKit

/// Pure, well-tested engine that anchors chapter prose to source segments and validates
/// pull-quote fidelity (KTD12). Provenance is computed post-hoc and never trusted from the
/// model: resolution is exact-first, then a windowed fuzzy fallback, else no link — never a
/// wrong one. W3C Web Annotation dual selectors (quote + position) make links re-resolvable
/// after regeneration; a content hash makes source edits detectable. All `nonisolated static`.
enum ProvenanceAnchor {

    /// TextQuoteSelector: the matched text plus its immediate context, which disambiguates a
    /// repeated quote and survives offset drift after regeneration.
    struct QuoteSelector: Codable, Equatable {
        var exact: String
        var prefix: String
        var suffix: String
    }

    /// TextPositionSelector: character offsets into the normalized source (a re-resolution
    /// hint; the quote selector is primary).
    struct PositionSelector: Codable, Equatable {
        var start: Int
        var end: Int
    }

    enum MatchStatus: String, Codable, Equatable {
        case exact
        case fuzzy
        case none
    }

    struct Match: Equatable {
        var status: MatchStatus
        var quote: QuoteSelector?
        var position: PositionSelector?
        var score: Double
        static let unmatched = Match(status: .none, quote: nil, position: nil, score: 0)
    }

    /// Normalized-similarity floor for a fuzzy link. Below this, no link is recorded.
    static let fuzzyThreshold = 0.85
    private static let contextWindow = 32

    // MARK: - Normalization

    /// Unicode NFC + collapsed whitespace + trimmed. The single normalization used by every
    /// operation so exact/fuzzy/hash all agree on what "the same text" means.
    static func normalize(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        let collapsed = nfc.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stable content hash of the normalized source, for staleness detection (KTD12).
    static func contentHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(normalize(s).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Quote validation

    /// True iff `quote` is an exact substring of `source` after normalization (KTD12). A
    /// pull-quote must be the person's exact words or be omitted — a paraphrase is rejected.
    static func isExactQuote(_ quote: String, of source: String) -> Bool {
        let q = normalize(quote)
        let s = normalize(source)
        return !q.isEmpty && s.contains(q)
    }

    // MARK: - Similarity

    /// Normalized similarity in [0, 1] (1 = identical after normalization). Uses a Levenshtein
    /// ratio — a robust stand-in for difflib's longest-matching-block ratio, which Swift has
    /// no stdlib equivalent for.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a))
        let y = Array(normalize(b))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        let dist = levenshtein(x, y)
        return 1 - Double(dist) / Double(max(x.count, y.count))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // MARK: - Resolve

    /// Locate `needle` within `source`: exact (normalized) first, then a windowed fuzzy match
    /// above `fuzzyThreshold`, else `.none`. `prefixHint`/`suffixHint` (from a prior anchor)
    /// disambiguate a repeated occurrence.
    static func resolve(
        needle rawNeedle: String,
        in rawSource: String,
        prefixHint: String = "",
        suffixHint: String = ""
    ) -> Match {
        let needle = normalize(rawNeedle)
        let source = normalize(rawSource)
        guard !needle.isEmpty, !source.isEmpty else { return .unmatched }

        let sourceChars = Array(source)
        let needleChars = Array(needle)

        let exactRanges = allExactRanges(of: needleChars, in: sourceChars)
        if !exactRanges.isEmpty {
            let chosen = disambiguate(
                exactRanges,
                in: sourceChars,
                prefixHint: normalize(prefixHint),
                suffixHint: normalize(suffixHint)
            )
            return makeMatch(range: chosen, in: sourceChars, status: .exact, score: 1)
        }

        if let (range, score) = bestFuzzyWindow(needle: needle, sourceChars: sourceChars),
           score >= fuzzyThreshold {
            return makeMatch(range: range, in: sourceChars, status: .fuzzy, score: score)
        }
        return .unmatched
    }

    // MARK: - Internals

    private static func allExactRanges(of needle: [Character], in source: [Character]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= source.count else { return [] }
        var ranges: [Range<Int>] = []
        var i = 0
        let last = source.count - needle.count
        while i <= last {
            if Array(source[i..<i + needle.count]) == needle {
                ranges.append(i..<i + needle.count)
            }
            i += 1
        }
        return ranges
    }

    private static func disambiguate(
        _ ranges: [Range<Int>],
        in source: [Character],
        prefixHint: String,
        suffixHint: String
    ) -> Range<Int> {
        guard prefixHint.count + suffixHint.count > 0, ranges.count > 1 else { return ranges[0] }
        var best = ranges[0]
        var bestScore = -1.0
        for range in ranges {
            let prefix = context(before: range.lowerBound, in: source)
            let suffix = context(after: range.upperBound, in: source)
            let score = similarity(prefix, prefixHint) + similarity(suffix, suffixHint)
            if score > bestScore {
                bestScore = score
                best = range
            }
        }
        return best
    }

    private static func context(before index: Int, in source: [Character]) -> String {
        let start = max(0, index - contextWindow)
        return String(source[start..<index])
    }

    private static func context(after index: Int, in source: [Character]) -> String {
        let end = min(source.count, index + contextWindow)
        return String(source[index..<end])
    }

    private static func makeMatch(
        range: Range<Int>,
        in source: [Character],
        status: MatchStatus,
        score: Double
    ) -> Match {
        let quote = QuoteSelector(
            exact: String(source[range]),
            prefix: context(before: range.lowerBound, in: source),
            suffix: context(after: range.upperBound, in: source)
        )
        return Match(
            status: status,
            quote: quote,
            position: PositionSelector(start: range.lowerBound, end: range.upperBound),
            score: score
        )
    }

    /// Slide word-windows (of the needle's word count, ±1) over the source and return the char
    /// range of the best-scoring window. Word-aligned so a fuzzy match never cuts mid-word.
    private static func bestFuzzyWindow(needle: String, sourceChars: [Character]) -> (Range<Int>, Double)? {
        let words = wordRanges(in: sourceChars)
        guard !words.isEmpty else { return nil }
        let needleWordCount = max(1, needle.split(separator: " ").count)

        var best: (Range<Int>, Double)?
        for k in Set([max(1, needleWordCount - 1), needleWordCount, needleWordCount + 1]) where k <= words.count {
            for start in 0...(words.count - k) {
                let charRange = words[start].lowerBound..<words[start + k - 1].upperBound
                let window = String(sourceChars[charRange])
                let score = similarity(needle, window)
                if best == nil || score > best!.1 {
                    best = (charRange, score)
                }
            }
        }
        return best
    }

    /// Character ranges of whitespace-delimited words in normalized (single-space) text.
    private static func wordRanges(in source: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (i, c) in source.enumerated() {
            if c == " " {
                if let s = start { ranges.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(s..<source.count) }
        return ranges
    }
}
