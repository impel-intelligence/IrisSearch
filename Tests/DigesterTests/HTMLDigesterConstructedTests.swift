//
//  HTMLDigesterConstructedTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-20.
//
//  Unlike HTMLandXMLTests.swift (which digests static fixture files from Test Documents/html),
//  every document here is built programmatically via SwiftSoup's element-builder API
//  (appendElement/attr/text), serialized, and written to a per-test temporary directory that is
//  torn down afterward. This makes it easy to isolate one specific behavior per test (a single
//  nested header, a single oversized paragraph, etc.) without needing a matching fixture file.
//
//  This file covers HTML documents specifically. See XMLDigesterConstructedTests.swift for the
//  XML/OPML side of HTMLandXMLDigester.

import Testing
@testable import Digester
import SwiftSoup
import IrisCommon
import Foundation

final class HTMLDigesterConstructedTests {
    private let digestor = HTMLandXMLDigester()
    private let workingDirectory: URL

    init() {
        workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HTMLDigesterConstructedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Builds a blank HTML document and hands its `<body>` to `build` for populating via SwiftSoup's element-builder API.
    private func makeDocument(_ build: (Element) throws -> Void) throws -> Document {
        let document = try SwiftSoup.parse("<html><head></head><body></body></html>")
        let body = try #require(document.body())
        try build(body)
        return document
    }

    /// Serializes `document` and writes it to a fresh file inside this test's temporary working directory.
    private func write(_ document: Document) throws -> URL {
        let fileURL = workingDirectory.appendingPathComponent("\(UUID().uuidString).html")
        let html = try document.outerHtml()
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func textChunks(in digest: [EmbeddableContent]) -> [(content: String, location: DocumentLocation)] {
        return digest.compactMap { piece in
            guard case let .text(content, location) = piece else { return nil }
            return (content, location)
        }
    }

    private func selectors(for location: DocumentLocation) -> [String] {
        guard case let .selector(selectors) = location.anchor else { return [] }
        return selectors
    }

    @Test("Each header produces its own chunk containing only its own body text")
    func headerSectioning() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "intro").text("Intro")
            try body.appendElement("p").text("Hello world.")
            try body.appendElement("h2").attr("id", "details").text("Details")
            try body.appendElement("p").text("More info.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 2, "One chunk should be produced per header")

        #expect(texts[0].content.contains("Intro"))
        #expect(texts[0].content.contains("Hello world."))
        #expect(!texts[0].content.contains("More info."), "Intro's chunk should not include Details' content")

        #expect(texts[1].content.contains("Details"))
        #expect(texts[1].content.contains("More info."))
        #expect(!texts[1].content.contains("Hello world."), "Details' chunk should not include Intro's content")
    }

    @Test("Table rows and captions are flattened into the section's text")
    func tableRendering() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "report").text("Report")

            let table = try body.appendElement("table")
            try table.appendElement("caption").text("Yearly Stats")

            let headerRow = try table.appendElement("tr")
            try headerRow.appendElement("th").text("Year")
            try headerRow.appendElement("th").text("Revenue")

            let row2024 = try table.appendElement("tr")
            try row2024.appendElement("td").text("2024")
            try row2024.appendElement("td").text("$100")

            let row2025 = try table.appendElement("tr")
            try row2025.appendElement("td").text("2025")
            try row2025.appendElement("td").text("$120")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        let content = try #require(texts.first?.content)
        #expect(content.contains("Year"))
        #expect(content.contains("Revenue"))
        #expect(content.contains("2024"))
        #expect(content.contains("$100"))
        #expect(content.contains("2025"))
        #expect(content.contains("$120"))
        #expect(content.contains("Yearly Stats"), "The table's caption should be included")
    }

    @Test("A header nested inside a wrapper element is still found via the recursive walk")
    func nestedHeaderIsFound() throws {
        let document = try makeDocument { body in
            let wrapper = try body.appendElement("div").attr("class", "wrapper")
            try wrapper.appendElement("h2").attr("id", "nested").text("Nested Section")
            try wrapper.appendElement("p").text("Nested body text.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("Nested Section") == true)
        #expect(texts.first?.content.contains("Nested body text.") == true)
    }

    @Test("A wrapper with no header/table/img descendants is captured as one leaf, including nested link text")
    func nonStructuralWrapperIsOneLeaf() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "links").text("Links")
            let list = try body.appendElement("ul")
            let item = try list.appendElement("li")
            try item.appendText("Reference: ")
            try item.appendElement("a").attr("href", "https://example.com").text("Example Site")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("Reference:") == true)
        #expect(texts.first?.content.contains("Example Site") == true, "Anchor text nested inside a non-structural wrapper should still be captured")
    }

    @Test("Content before the first header becomes its own leading section")
    func orphanedContentWithoutTitle() throws {
        let document = try makeDocument { body in
            try body.appendElement("p").text("Welcome to the document.")
            try body.appendElement("h1").attr("id", "later").text("Later Section")
            try body.appendElement("p").text("Later content.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 2, "The orphaned content and the later header should each produce their own chunk")
        #expect(texts[0].content.contains("Welcome to the document."), "Without a <title>, the first orphaned piece's text becomes the section's header")
        #expect(texts[1].content.contains("Later Section"))
        #expect(texts[1].content.contains("Later content."))
    }

    @Test("The first orphaned piece still appears as content when a <title> is present")
    func orphanedContentWithTitleKeepsFirstPiece() throws {
        let document = try makeDocument { body in
            try body.appendElement("p").text("Welcome to the document.")
            try body.appendElement("p").text("A second orphaned paragraph.")
            try body.appendElement("h1").attr("id", "later").text("Later Section")
        }
        try document.head()?.appendElement("title").text("My Document")

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.first?.content.contains("Welcome to the document.") == true, "The first orphaned paragraph's text should still appear as content even when a <title> supplies the header text")
        #expect(texts.first?.content.contains("A second orphaned paragraph.") == true)
    }

    @Test("A single piece larger than contextSize is split by SentenceChunker, with the header prefix embedded in every sub-chunk")
    func oversizedPieceIsSplitWithPrefix() throws {
        let sentence = "This is one sentence in a very long paragraph that keeps going. "
        let longText = String(repeating: sentence, count: 40)

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "wall-of-text").text("Wall of Text")
            try body.appendElement("p").text(longText)
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 200)
        let texts = textChunks(in: digest)

        #expect(texts.count > 1, "Test precondition: the paragraph should be too large to fit in a single 200-character chunk")

        for chunk in texts {
            #expect(chunk.content.contains("Wall of Text"), "Every sub-chunk produced by SentenceChunker should still carry the section's header prefix")
        }
    }

    @Test("Several small pieces that together exceed contextSize are packed into multiple chunks, each carrying the header prefix")
    func binPackedChunksAllCarryHeaderPrefix() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "notes").text("Notes")
            for index in 1...10 {
                try body.appendElement("p").text("This is note number \(index), and it takes up a bit of space on its own.")
            }
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 150)
        let texts = textChunks(in: digest)

        #expect(texts.count > 1, "Test precondition: ten notes should not all fit in a single 150-character chunk")

        for chunk in texts {
            #expect(chunk.content.contains("Notes"), "Every packed chunk should carry the section header prefix")
        }

        // Matches the sequenceIndex/documentLength convention exercised in TXTTests/PDFTests.
        let sequenceIndices = texts.map { $0.location.sequenceIndex }.sorted()
        #expect(sequenceIndices == Array(0..<texts.count), "sequenceIndex values should be contiguous 0..<documentLength")
        for chunk in texts {
            #expect(chunk.location.documentLength == texts.count, "documentLength should match the actual number of returned chunks")
        }
    }

    @Test("No chunk has an empty selector list, even when a section ends with an oversized piece")
    func noTrailingEmptyChunkAfterOversizedLastPiece() throws {
        let sentence = "This is one sentence in a very long paragraph that keeps going. "
        let longText = String(repeating: sentence, count: 40)

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "mixed").text("Mixed Section")
            try body.appendElement("p").text("A short piece first.")
            try body.appendElement("p").text(longText) // oversized, and the LAST piece in the section
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 200)
        let texts = textChunks(in: digest)

        for chunk in texts {
            #expect(!selectors(for: chunk.location).isEmpty, "No returned chunk should have an empty selector list — that indicates a trailing header-only chunk with no real content")
        }
    }

    // Images are recognized during the walk (see HTMLandXMLDigester.walk's "img" branch) but
    // digest()'s `case .image` currently just `break`s — there's a `// TODO: Add support for
    // image loading` marker on that line. This test documents today's behavior so it fails loudly
    // (as a reminder to update it) once that TODO is implemented, rather than silently passing.
    @Test("Images are recognized but not yet emitted as EmbeddableContent (pending image-loading support)")
    func imagesAreNotYetEmitted() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "photo.png").attr("alt", "A photo")
            try body.appendElement("p").text("Caption text.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)

        let imageCount = digest.count { piece in
            if case .image = piece { return true }
            return false
        }

        #expect(imageCount == 0, "Image loading is a pending TODO in digest() — update this test once EmbeddableContent.image pieces are emitted")
        #expect(textChunks(in: digest).first?.content.contains("Caption text.") == true, "Non-image content in the same section should still be captured")
    }

    // The tests below lock in walk()'s node-level iteration (walking every child node, not just
    // child Elements) and the shared SectionBuilder — regression coverage for the two bugs found
    // while testing against mixed-content.html (see HTMLandXMLTests.swift's Image Gallery /
    // Inline and Linked Images tests for the same behavior against real fixture content).

    @Test("Text directly beside an inline image is preserved and stays in document order")
    func textAroundInlineImageIsPreserved() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            let paragraph = try body.appendElement("p")
            try paragraph.appendText("Before the image.")
            try paragraph.appendElement("img").attr("src", "icon.png").attr("alt", "an icon")
            try paragraph.appendText("After the image.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        let content = try #require(texts.first?.content)
        #expect(content.contains("Before the image."))
        #expect(content.contains("After the image."))

        let beforeRange = try #require(content.range(of: "Before the image."))
        let afterRange = try #require(content.range(of: "After the image."))
        #expect(beforeRange.lowerBound < afterRange.lowerBound, "Text should stay in document order relative to the image it surrounds")
    }

    @Test("A <figure> wrapping an image and caption is attributed to the currently active section")
    func figureContentAttributedToActiveSection() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            let figure = try body.appendElement("figure")
            try figure.appendElement("img").attr("src", "photo.png").attr("alt", "a photo")
            try figure.appendElement("figcaption").text("Figure 1: A nice photo.")
            try body.appendElement("h1").attr("id", "closing").text("Closing")
            try body.appendElement("p").text("The end.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 2, "Exactly two sections should be produced: Gallery and Closing")

        let galleryChunk = try #require(texts.first { $0.content.contains("Gallery") })
        #expect(galleryChunk.content.contains("Figure 1: A nice photo."), "The figcaption should be attributed to the Gallery section, not dropped or misplaced")

        let closingChunk = try #require(texts.first { $0.content.contains("Closing") })
        #expect(!closingChunk.content.contains("Figure 1"), "The figure's caption should not leak into a later section")
    }

    @Test("Loose text with no wrapping tag at all is still captured, not silently dropped")
    func looseTopLevelTextIsCaptured() throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "notes").text("Notes")
            try body.appendText("A stray sentence with no wrapping tag at all.")
            try body.appendElement("p").text("A normal wrapped paragraph.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("A stray sentence with no wrapping tag at all.") == true)
        #expect(texts.first?.content.contains("A normal wrapped paragraph.") == true)
    }

    @Test("Whitespace-only text between elements does not produce spurious extra pieces")
    func whitespaceOnlyTextIsIgnored() throws {
        // Simulates hand-formatted HTML with newlines/indentation between tags — appendText
        // inserts a literal whitespace-only TextNode as a direct sibling, matching how real files
        // are authored (see headers.html, which is full of these).
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "notes").text("Notes")
            try body.appendText("\n    ")
            try body.appendElement("p").text("First paragraph.")
            try body.appendText("\n    ")
            try body.appendElement("p").text("Second paragraph.")
            try body.appendText("\n")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        let chunk = try #require(texts.first)
        #expect(chunk.content.contains("First paragraph."))
        #expect(chunk.content.contains("Second paragraph."))

        // Exactly the two real paragraphs should have contributed a selector. If whitespace-only
        // TextNodes between them weren't filtered via isBlank() (not just .isEmpty on the
        // normalized text — normalization can collapse "\n    " down to a single space, which is
        // non-empty), each one would add a spurious extra selector here.
        #expect(selectors(for: chunk.location).count == 2, "Whitespace-only text nodes should not contribute their own pieces/selectors")
    }
}
