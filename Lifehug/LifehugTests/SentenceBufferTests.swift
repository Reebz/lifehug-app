import Testing
@testable import Lifehug

@Suite("SentenceBuffer")
struct SentenceBufferTests {

    // MARK: - Basic Punctuation Extraction

    @Test("Period followed by space extracts sentence")
    func periodExtraction() {
        var buffer = SentenceBuffer()
        buffer.append("Hello world. More text")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Hello world.")
    }

    @Test("Exclamation mark followed by space extracts sentence")
    func exclamationExtraction() {
        var buffer = SentenceBuffer()
        buffer.append("Wow! That's great.")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Wow!")
    }

    @Test("Question mark followed by space extracts sentence")
    func questionMarkExtraction() {
        var buffer = SentenceBuffer()
        buffer.append("Really? I had no idea.")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Really?")
    }

    // MARK: - Abbreviation Handling

    @Test("Dr. abbreviation does not split")
    func drAbbreviation() {
        var buffer = SentenceBuffer()
        buffer.append("Dr. Smith is here. Next sentence")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Dr. Smith is here.")
    }

    @Test("Mrs. abbreviation does not split")
    func mrsAbbreviation() {
        var buffer = SentenceBuffer()
        buffer.append("Mrs. Jones left. Then it happened")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Mrs. Jones left.")
    }

    @Test("U.S. abbreviation does not split")
    func usAbbreviation() {
        var buffer = SentenceBuffer()
        buffer.append("The U.S. is large. Very large")
        let sentence = buffer.extractSentence()
        #expect(sentence == "The U.S. is large.")
    }

    // MARK: - Decimal Numbers

    @Test("Decimal number 3.50 does not split")
    func decimalNumber() {
        var buffer = SentenceBuffer()
        buffer.append("It cost 3.50 dollars. That's cheap")
        let sentence = buffer.extractSentence()
        #expect(sentence == "It cost 3.50 dollars.")
    }

    // MARK: - Ellipsis

    @Test("Ellipsis does not split")
    func ellipsisDoesNotSplit() {
        var buffer = SentenceBuffer()
        buffer.append("Wait... I remember now. Yes")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Wait... I remember now.")
    }

    // MARK: - End of Buffer

    @Test("Period at end of buffer with no trailing space extracts sentence")
    func periodAtEndOfBuffer() {
        var buffer = SentenceBuffer()
        buffer.append("This is complete.")
        let sentence = buffer.extractSentence()
        #expect(sentence == "This is complete.")
    }

    // MARK: - No Terminator

    @Test("No terminator returns nil")
    func noTerminatorReturnsNil() {
        var buffer = SentenceBuffer()
        buffer.append("This has no ending punctuation")
        let sentence = buffer.extractSentence()
        #expect(sentence == nil)
    }

    // MARK: - Multiple Sentences

    @Test("Multiple sentences extracted sequentially")
    func multipleSentences() {
        var buffer = SentenceBuffer()
        buffer.append("First. Second. Third.")
        let s1 = buffer.extractSentence()
        let s2 = buffer.extractSentence()
        let s3 = buffer.extractSentence()
        #expect(s1 == "First.")
        #expect(s2 == "Second.")
        #expect(s3 == "Third.")
    }

    // MARK: - Empty Buffer

    @Test("Empty buffer returns nil")
    func emptyBufferReturnsNil() {
        var buffer = SentenceBuffer()
        let sentence = buffer.extractSentence()
        #expect(sentence == nil)
    }

    // MARK: - Append Accumulates

    @Test("Append accumulates text across calls")
    func appendAccumulates() {
        var buffer = SentenceBuffer()
        buffer.append("Hello ")
        buffer.append("world. ")
        buffer.append("More")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Hello world.")
    }

    // MARK: - Flush

    @Test("Flush returns remaining text and clears buffer")
    func flushReturnsRemaining() {
        var buffer = SentenceBuffer()
        buffer.append("Some incomplete text")
        let flushed = buffer.flush()
        #expect(flushed == "Some incomplete text")
        // Buffer should now be empty
        let afterFlush = buffer.extractSentence()
        #expect(afterFlush == nil)
    }

    @Test("Flush on empty buffer returns empty string")
    func flushEmptyReturnsEmpty() {
        var buffer = SentenceBuffer()
        let flushed = buffer.flush()
        #expect(flushed == "")
    }

    // MARK: - Short Fragment

    @Test("Short fragment Hi. extracts correctly")
    func shortFragment() {
        var buffer = SentenceBuffer()
        buffer.append("Hi.")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Hi.")
    }

    // MARK: - Newline Boundary

    @Test("Newline after period splits sentence")
    func newlineAfterPeriod() {
        var buffer = SentenceBuffer()
        buffer.append("Done.\nNext line")
        let sentence = buffer.extractSentence()
        #expect(sentence == "Done.")
    }

    // MARK: - Period Without Trailing Space

    @Test("Period followed by non-space character does not split")
    func periodNoSpaceDoesNotSplit() {
        var buffer = SentenceBuffer()
        buffer.append("file.txt is here")
        let sentence = buffer.extractSentence()
        #expect(sentence == nil)
    }
}
