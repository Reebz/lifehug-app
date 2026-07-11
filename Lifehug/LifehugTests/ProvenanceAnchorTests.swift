import Testing
import Foundation
@testable import Lifehug

@Suite("ProvenanceAnchor")
struct ProvenanceAnchorTests {

    // MARK: - Exact match

    @Test("Exact match is found and positioned")
    func exactMatch() {
        let source = "I remember the garden vividly."
        let m = ProvenanceAnchor.resolve(needle: "the garden", in: source)
        #expect(m.status == .exact)
        #expect(m.score == 1.0)
        #expect(m.quote?.exact == "the garden")
        if let pos = m.position {
            #expect(String(Array(source)[pos.start..<pos.end]) == "the garden")
        }
    }

    @Test("Repeated quote is disambiguated by prefix/suffix hints")
    func repeatedDisambiguation() {
        let source = "red car. blue sky. red car."
        let m = ProvenanceAnchor.resolve(needle: "red car", in: source, prefixHint: "blue sky.", suffixHint: ".")
        #expect(m.status == .exact)
        // Second occurrence starts at index 19 ("red car. blue sky. ").
        #expect(m.position?.start == 19)
    }

    // MARK: - Fuzzy match

    @Test("Fuzzy match above threshold survives punctuation drift")
    func fuzzyMatch() {
        let source = "I walked to the store, slowly, that evening."
        let m = ProvenanceAnchor.resolve(needle: "walked to the store slowly", in: source)
        #expect(m.status == .fuzzy)
        #expect(m.score >= ProvenanceAnchor.fuzzyThreshold)
    }

    @Test("Near-miss below threshold returns none, never a wrong anchor")
    func nearMissNone() {
        let m = ProvenanceAnchor.resolve(needle: "completely unrelated sentence here", in: "I remember the garden vividly.")
        #expect(m.status == .none)
        #expect(m.quote == nil)
    }

    // MARK: - Quote validation

    @Test("Quote validation accepts exact substrings, rejects paraphrase")
    func quoteValidation() {
        #expect(ProvenanceAnchor.isExactQuote("the garden", of: "I remember the garden."))
        #expect(ProvenanceAnchor.isExactQuote("the  garden", of: "I remember the garden."))  // whitespace drift ok
        #expect(!ProvenanceAnchor.isExactQuote("garden paradise", of: "I remember the garden."))
        #expect(!ProvenanceAnchor.isExactQuote("", of: "anything"))
    }

    // MARK: - Staleness

    @Test("Content hash is whitespace/NFC-stable and edit-sensitive")
    func contentHashStaleness() {
        let h1 = ProvenanceAnchor.contentHash("the yellow wallpaper")
        let h2 = ProvenanceAnchor.contentHash("the   yellow\n wallpaper")  // same after normalize
        let h3 = ProvenanceAnchor.contentHash("the blue wallpaper")       // edited source
        #expect(h1 == h2)
        #expect(h1 != h3)
    }

    // MARK: - Degenerate inputs

    @Test("Empty and degenerate inputs never crash and never match")
    func degenerateInputs() {
        #expect(ProvenanceAnchor.resolve(needle: "", in: "source").status == .none)
        #expect(ProvenanceAnchor.resolve(needle: "x", in: "").status == .none)
        #expect(ProvenanceAnchor.similarity("", "") == 1.0)
        #expect(ProvenanceAnchor.similarity("a", "") == 0.0)
    }

    // MARK: - Re-resolution after regeneration

    @Test("Anchor re-resolves in regenerated prose that kept the passage, none when it didn't")
    func reResolveAfterRegeneration() {
        let original = "She loved the yellow wallpaper in the kitchen."
        let anchor = ProvenanceAnchor.resolve(needle: "the yellow wallpaper", in: original)
        #expect(anchor.status == .exact)

        let quote = anchor.quote!
        let survived = ProvenanceAnchor.resolve(
            needle: quote.exact,
            in: "In the kitchen, the yellow wallpaper still glowed.",
            prefixHint: quote.prefix,
            suffixHint: quote.suffix
        )
        #expect(survived.status == .exact)

        let gone = ProvenanceAnchor.resolve(needle: "the yellow wallpaper", in: "The room was entirely bare and cold.")
        #expect(gone.status == .none)
    }
}
