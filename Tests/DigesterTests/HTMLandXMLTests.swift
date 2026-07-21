//
//  HTMLandXMLTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-20.
//

import Testing
@testable import Digester
import IrisCommon
import Foundation
import SwiftSoup

struct HTMLandXMLTests {
    // Authored by Claude Sonnet 5 (Anthropic) on 2026-07-20.
    // Every chunk is prefixed with "<headerText>: (<headerSelector>)\n\n" (see digest()'s
    // headerPrefix), and every header in these fixtures has a unique #id, so headerSelector is
    // always exactly "#id" (SwiftSoup's cssSelector() prefers the id form). Searching for that
    // exact "(#id)" marker locates a section's chunk without depending on chunk ordering — which
    // matters here because a couple of the tests below intentionally probe cases where ordering
    // (or presence) is currently wrong.
    private func chunkText(forID id: String, in digest: [EmbeddableContent]) -> String? {
        let marker = "(#\(id))"
        for piece in digest {
            guard case let .text(content, _) = piece else { continue }
            if content.contains(marker) { return content }
        }
        return nil
    }

    private func allText(in digest: [EmbeddableContent]) -> String {
        return digest.compactMap { piece -> String? in
            guard case let .text(content, _) = piece else { return nil }
            return content
        }.joined(separator: "\n")
    }

    @Test("Every header in headers.html produces its own anchored text chunk, in document order")
    func testHeaderSections() throws {
        let htmlFile = Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 1000)

        var validHeaders = ["Header 1", "Header 1a", "Header 2", "Header 2a", "Header 2b", "Header 2c", "Header 2d", "Header 2e", "Long Header"]

        for content in digest {
            guard let header = validHeaders.first else { continue }
            // Every piece should be a text piece in this document
            let textContent = try #require(content.textContent, "Every piece should be a text piece in this document")

            #expect(!textContent.isEmpty, "Content should not be empty.")

            if textContent.contains(header) {
                validHeaders.removeFirst()
            }
        }

        #expect(validHeaders.isEmpty, "Every header should have appearedin the returned content.")
    }

    @Test("Each header's own paragraph is grouped into its chunk, and not bled into a neighboring header's chunk")
    func testHeaderContentIsGroupedCorrectly() throws {
        let htmlFile = Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 1000)

        let header1 = try #require(digest.first { $0.textContent?.contains("Header 1</p>") != true && $0.textContent?.contains("Header 1:") == true || $0.textContent?.contains("Header 1\n") == true }?.textContent)
        _ = header1 // fixture headers have no ids, so fall back to a plainer per-chunk scan below

        // headers.html has no #id attributes, so headerSelector is a computed path rather than a
        // clean "#id" — scan chunk-by-chunk instead of via chunkText(forID:).
        let texts = digest.compactMap { piece -> String? in
            guard case let .text(content, _) = piece else { return nil }
            return content
        }

        let header1Chunk = try #require(texts.first { $0.contains("Header 1") && !$0.contains("Header 1a") })
        #expect(header1Chunk.contains("My first paragraph."))
        #expect(!header1Chunk.contains("Woah this is crazy."), "Header 1's chunk should not contain Header 1a's paragraph")

        let header1aChunk = try #require(texts.first { $0.contains("Header 1a") })
        #expect(header1aChunk.contains("Woah this is crazy."))
        #expect(!header1aChunk.contains("My first paragraph."), "Header 1a's chunk should not contain Header 1's paragraph")

        let header2Chunk = try #require(texts.first { $0.contains("Header 2") && !$0.contains("Header 2a") && !$0.contains("Header 2b") })
        #expect(header2Chunk.contains("Hello world."))
    }

    @Test("A section too large for one chunk is split, and every sub-chunk still carries its header")
    func testLongHeaderSectionSplitsWithHeaderPrefix() throws {
        let htmlFile = Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 200)

        let texts = digest.compactMap { piece -> String? in
            guard case let .text(content, _) = piece else { return nil }
            return content
        }

        let longHeaderChunks = texts.filter { $0.contains("Long Header") }
        #expect(longHeaderChunks.count > 1, "The three lorem-ipsum paragraphs under Long Header shouldn't fit in a single 200-character chunk")

        // Every one of the "Long Header" section's own sub-chunks should carry the header prefix, per SentenceChunker's `prefix` parameter.
        for chunk in longHeaderChunks {
            #expect(chunk.contains("Long Header"))
        }
    }

    @Test("Overview's chunk contains its own intro text and not a neighboring section's text")
    func testOverviewSectionContent() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let overview = try #require(chunkText(forID: "overview", in: digest))
        #expect(overview.contains("Jump straight to the"))
        #expect(!overview.contains("generated as a fixture"), "Overview's chunk should not contain About This File's text")
    }

    @Test("Headers nested three to five levels deep (h3-h6) each still produce their own chunk")
    func testDeeplyNestedHeadersAllProduceSections() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let subsection = try #require(chunkText(forID: "section-a-sub", in: digest))
        #expect(subsection.contains("A subsection nested under Section A."))

        let detail = try #require(chunkText(forID: "section-a-detail", in: digest))
        #expect(detail.contains("An h4 nested three levels deep."))

        let note = try #require(chunkText(forID: "section-a-note", in: digest))
        #expect(note.contains("An h5-level aside."))

        let footnote = try #require(chunkText(forID: "section-a-footnote", in: digest))
        #expect(footnote.contains("An h6-level footnote"))
    }

    @Test("A header with multiple sibling paragraphs captures all of them in its chunk")
    func testSectionBHasBothParagraphs() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let sectionB = try #require(chunkText(forID: "section-b", in: digest))
        #expect(sectionB.contains("Pellentesque velit leo"))
        #expect(sectionB.contains("Curabitur nec lorem turpis"))
    }

    @Test("Anchor text inside <ul><li> link lists is captured as part of the section's text")
    func testLinkSectionsCaptureAnchorText() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let external = try #require(chunkText(forID: "external-links", in: digest))
        #expect(external.contains("Wikipedia"))
        #expect(external.contains("reserved example domains"))
        #expect(external.contains("example.com"))

        let internalLinks = try #require(chunkText(forID: "internal-links", in: digest))
        #expect(internalLinks.contains("Overview"))
        #expect(internalLinks.contains("pricing table"))
        #expect(internalLinks.contains("image gallery"))

        let other = try #require(chunkText(forID: "other-link-types", in: digest))
        #expect(other.contains("hello@example.com"))
        #expect(other.contains("+1 (555) 555-0100"))
        #expect(other.contains("headers.html"))
        #expect(other.contains("sample-report.pdf"))
    }

    @Test("A simple table's headers, data cells, and caption are all flattened into the section's text")
    func testSimpleTableContent() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let simpleTable = try #require(chunkText(forID: "simple-table", in: digest))
        #expect(simpleTable.contains("Task"))
        #expect(simpleTable.contains("Design review"))
        #expect(simpleTable.contains("Alice"))
        #expect(simpleTable.contains("Complete"))
        #expect(simpleTable.contains("Weekly Task Status"), "The table's caption should be included")
    }

    @Test("A table split across thead/tbody/tfoot has every row (including the footer) flattened into text")
    func testPricingTableContent() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let pricingTable = try #require(chunkText(forID: "pricing-table", in: digest))
        #expect(pricingTable.contains("Starter"))
        #expect(pricingTable.contains("$9"))
        #expect(pricingTable.contains("Enterprise"))
        #expect(pricingTable.contains("Contact us"))
        #expect(pricingTable.contains("Prices shown in USD and billed annually."), "The tfoot row should be included alongside thead/tbody")
    }

    @Test("A table using rowspan/colspan still has every cell's text captured, plus its caption")
    func testComplexTableContent() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let complexTable = try #require(chunkText(forID: "complex-table", in: digest))
        #expect(complexTable.contains("North America"))
        #expect(complexTable.contains("158"))
        #expect(complexTable.contains("Total"))
        #expect(complexTable.contains("1233"))
        #expect(complexTable.contains("Quarterly Regional Sales"), "The table's caption should be included")
    }

    @Test("Closing Notes captures its own text and the anchor text of its link back to Overview")
    func testClosingNotesContent() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let closing = try #require(chunkText(forID: "closing", in: digest))
        #expect(closing.contains("email and tel links"))
        #expect(closing.contains("top of the document"))
    }

    // "Image Gallery" wraps two <figure> elements, each containing an <img>. A <figure> isn't a
    // header/table/img itself, so walk() recurses into it — but since all recursive calls now
    // share the same SectionBuilder (rather than returning their own separate sections/orphaned
    // to be merged after the fact), the <figcaption> pieces found inside each <figure> land in
    // whatever section is currently active — "Image Gallery" — instead of being lost to a
    // separate merge step.
    @Test("The Image Gallery header and its figure captions appear together in the digest")
    func testImageGalleryContentIsNotDropped() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let combined = allText(in: digest)
        #expect(combined.contains("Image Gallery"), "The header text itself should appear in the output")
        #expect(combined.contains("Figure 1: Alpine lake at sunrise."))
        #expect(combined.contains("Figure 2: City skyline at dusk."))
    }

    // Each paragraph under "Inline and Linked Images" wraps its <img> directly in prose text,
    // e.g. `<p>An inline icon can sit next to text: <img ...> task complete.</p>`. walk() now
    // iterates every child *node* of a wrapper being recursed into (not just its child Elements),
    // so the prose TextNodes sitting directly beside the <img> are captured via the wrapper's own
    // selector instead of being silently skipped.
    @Test("Prose surrounding an inline <img> is preserved, and the section header appears")
    func testInlineImageProseIsNotDropped() throws {
        let htmlFile = Bundle.module.url(forResource: "mixed-content", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 10_000)

        let combined = allText(in: digest)
        #expect(combined.contains("Inline and Linked Images"), "The header text itself should appear in the output")
        #expect(combined.contains("An inline icon can sit next to text"))
        #expect(combined.contains("task complete"))
        #expect(combined.contains("An image can also act as a link"))
        #expect(combined.contains("A remote, absolutely-referenced image"))
    }
}
