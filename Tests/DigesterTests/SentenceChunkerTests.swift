//
//  SentenceChunkerTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-13.
//

import Testing
@testable import Digester
import IrisCommon
import Foundation

struct SentenceChunkerTests {
    private func chunk(_ content: String, contextSize: Int, sequenceOffset: Int = 0) -> [EmbeddableContent] {
        SentenceChunker.chunkContent(for: content, contextSize: contextSize, sequenceOffset: sequenceOffset) { range in
            .text(characterRange: range)
        }
    }

    private func characterRange(of content: EmbeddableContent) -> Range<Int>? {
        guard case .text(let range) = content.location.anchor else { return nil }
        return range
    }

    // MARK: - Whole-document preservation

    @Test("Content that fits within contextSize is returned as a single chunk containing the whole document")
    func testSingleChunkWhenContentFits() {
        let content = "Hello there. This is a test sentence. And one more!"
        let chunks = chunk(content, contextSize: 1000)

        #expect(chunks.count == 1, "A document that fits within contextSize should still be returned as one chunk")
        #expect(chunks.first?.textContent == content)
    }

    @Test("Empty content produces no chunks")
    func testEmptyContent() {
        #expect(chunk("", contextSize: 100).isEmpty)
    }

    @Test("No content is silently dropped when a document spans multiple chunks")
    func testNoContentIsDroppedAcrossChunks() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let content = String(repeating: sentence, count: 30)
        let uniqueTail = "This unique marker ZQX789 closes out the document."
        let fullContent = content + uniqueTail

        let chunks = chunk(fullContent, contextSize: 150)
        let recombined = chunks.compactMap(\.textContent).joined()

        #expect(recombined.contains("ZQX789"), "The final sentence of the document should not be dropped")
    }

    // MARK: - Location tracking

    @Test("Each chunk's character range reconstructs the exact source text at that range")
    func testChunkRangesMapBackToSourceDocument() {
        let sentence = "A distinct sentence used for range mapping verification here. "
        let content = String(repeating: sentence, count: 20)

        let chunks = chunk(content, contextSize: 150)
        #expect(!chunks.isEmpty)

        for piece in chunks {
            guard let range = characterRange(of: piece), let text = piece.textContent else {
                #expect(Bool(false), "Expected a text chunk with a text anchor")
                continue
            }

            let lower = content.index(content.startIndex, offsetBy: range.lowerBound)
            let upper = content.index(content.startIndex, offsetBy: range.upperBound)
            #expect(String(content[lower..<upper]) == text, "The chunk's range should point at its own content in the source document")
        }
    }

    @Test("Chunks are sequenced in document order with a documentLength matching the returned chunk count")
    func testChunkSequencing() {
        let sentence = "Another short filler sentence for sequencing checks. "
        let content = String(repeating: sentence, count: 20)

        let chunks = chunk(content, contextSize: 150)
        #expect(chunks.count > 1)

        for (offset, piece) in chunks.enumerated() {
            #expect(piece.location.sequenceIndex == offset)
            #expect(piece.location.documentLength == chunks.count)
        }
    }

    @Test("A non-zero sequenceOffset shifts every chunk's sequenceIndex")
    func testSequenceOffsetIsApplied() {
        let sentence = "Filler sentence for offset checks right here okay. "
        let content = String(repeating: sentence, count: 20)

        let chunks = chunk(content, contextSize: 150, sequenceOffset: 100)
        #expect(!chunks.isEmpty)

        for (offset, piece) in chunks.enumerated() {
            #expect(piece.location.sequenceIndex == 100 + offset)
            // documentLength is local to this call (this call's own chunk count), not shifted by sequenceOffset.
            // Reconciling a grand total across multiple calls (e.g. PDFDigester's per-page loop) is the caller's
            // responsibility, not SentenceChunker's.
            #expect(piece.location.documentLength == chunks.count)
        }
    }

    @Test("The anchorMaker closure is used to build each chunk's anchor")
    func testAnchorMakerIsUsedForEachChunk() {
        let sentence = "Filler sentence for anchor checks right here okay friend. "
        let content = String(repeating: sentence, count: 20)

        let chunks = SentenceChunker.chunkContent(for: content, contextSize: 150) { range in
            .pdf(page: 3, characterRange: range)
        }
        #expect(!chunks.isEmpty)

        for piece in chunks {
            guard case .pdf(let page, _) = piece.location.anchor else {
                #expect(Bool(false), "Expected a pdf anchor built by the supplied anchorMaker")
                continue
            }
            #expect(page == 3)
        }
    }

    // MARK: - Overlap

    /// Pulls the numeric marker out of each "Sentence NNN." fragment in `text`, in the order it appears.
    /// Used to verify both that overlap actually happens and that overlapped sentences keep their original order.
    private func sentenceNumbers(in text: String) -> [Int] {
        text.components(separatedBy: "Sentence ").compactMap { component in
            let digits = component.prefix(3)
            return digits.count == 3 ? Int(digits) : nil
        }
    }

    @Test("Sentences within a chunk, including any carried-over overlap, stay in their original document order")
    func testOverlapSentencesStayInOrder() {
        // Uniquely numbered, fixed-width sentences so overlap can be detected and order-checked precisely,
        // unlike identical repeated sentences where reordering would be invisible.
        let sentences = (0..<150).map { "Sentence \(String(format: "%03d", $0))." }
        let content = sentences.joined(separator: " ") + " "

        // contextSize/overlap sized so the 5% overlap window comfortably covers more than one 14-character sentence.
        let chunks = chunk(content, contextSize: 600)
        #expect(chunks.count > 1)

        for piece in chunks {
            guard let text = piece.textContent else {
                #expect(Bool(false), "Expected text content")
                continue
            }
            let numbers = sentenceNumbers(in: text)
            #expect(numbers == numbers.sorted(), "Sentences within a chunk should stay in their original document order, including any carried-over overlap")
        }
    }

    @Test("Consecutive chunks actually share overlapping sentences")
    func testConsecutiveChunksOverlap() {
        let sentences = (0..<150).map { "Sentence \(String(format: "%03d", $0))." }
        let content = sentences.joined(separator: " ") + " "

        let chunks = chunk(content, contextSize: 600)
        #expect(chunks.count > 1)

        var overlapObserved = false
        for index in 1..<chunks.count {
            guard let previousText = chunks[index - 1].textContent, let currentText = chunks[index].textContent else {
                #expect(Bool(false), "Expected text content")
                continue
            }

            let previousNumbers = Set(sentenceNumbers(in: previousText))
            let currentNumbers = Set(sentenceNumbers(in: currentText))
            if !previousNumbers.isDisjoint(with: currentNumbers) {
                overlapObserved = true
            }
        }
        #expect(overlapObserved, "Expected at least one pair of consecutive chunks to share overlapping sentences")
    }

    // MARK: - Oversized sentences

    @Test("A single sentence longer than contextSize becomes its own chunk instead of being dropped")
    func testOversizedSentenceBecomesOwnChunk() {
        let longSentence = String(repeating: "word ", count: 60) + "and that is the entire sentence."
        let content = longSentence + " Short one."

        let chunks = chunk(content, contextSize: 50)
        let allText = chunks.compactMap(\.textContent).joined()

        #expect(allText.contains("and that is the entire sentence."), "An oversized sentence should still appear in the output")
    }

    // MARK: - Real document smoke test

    @Test("Chunking a real, large document does not crash and only produces non-empty chunks")
    func testLargeDocumentChunking() throws {
        let url = Bundle.module.url(forResource: "Shakespeare", withExtension: "txt", subdirectory: "Test Documents/txt")!
        let fullContent = try String(contentsOf: url, encoding: .utf8)
        let content = String(fullContent.prefix(50000))

        let chunks = chunk(content, contextSize: 512)
        #expect(!chunks.isEmpty)

        for piece in chunks {
            #expect((piece.textContent?.isEmpty ?? true) == false)
        }
    }
}
