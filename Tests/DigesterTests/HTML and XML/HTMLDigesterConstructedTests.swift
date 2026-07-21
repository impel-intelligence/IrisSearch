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

    private func imageChunks(in digest: [EmbeddableContent]) -> [(content: Data, caption: String?, location: DocumentLocation)] {
        return digest.compactMap { piece in
            guard case let .image(content, caption, location) = piece else { return nil }
            return (content, caption, location)
        }
    }

    // A minimal valid 1x1 transparent PNG, so ImageDecoder's isValidImageData() check (which
    // decodes via ImageIO) actually succeeds — an empty or arbitrary byte blob would not.
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    /// Writes a real, tiny, decodable PNG into this test's working directory (as a sibling of
    /// wherever the HTML document itself gets written), so a relative `src="name"` resolves to it.
    @discardableResult
    private func writeTestImage(name: String = "photo.png") throws -> URL {
        let data = try #require(Data(base64Encoded: HTMLDigesterConstructedTests.tinyPNGBase64))
        let url = workingDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("Each header produces its own chunk containing only its own body text")
    func headerSectioning() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "intro").text("Intro")
            try body.appendElement("p").text("Hello world.")
            try body.appendElement("h2").attr("id", "details").text("Details")
            try body.appendElement("p").text("More info.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
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
    func tableRendering() async throws {
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
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
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
    func nestedHeaderIsFound() async throws {
        let document = try makeDocument { body in
            let wrapper = try body.appendElement("div").attr("class", "wrapper")
            try wrapper.appendElement("h2").attr("id", "nested").text("Nested Section")
            try wrapper.appendElement("p").text("Nested body text.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("Nested Section") == true)
        #expect(texts.first?.content.contains("Nested body text.") == true)
    }

    @Test("A wrapper with no header/table/img descendants is captured as one leaf, including nested link text")
    func nonStructuralWrapperIsOneLeaf() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "links").text("Links")
            let list = try body.appendElement("ul")
            let item = try list.appendElement("li")
            try item.appendText("Reference: ")
            try item.appendElement("a").attr("href", "https://example.com").text("Example Site")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("Reference:") == true)
        #expect(texts.first?.content.contains("Example Site") == true, "Anchor text nested inside a non-structural wrapper should still be captured")
    }

    @Test("Content before the first header becomes its own leading section")
    func orphanedContentWithoutTitle() async throws {
        let document = try makeDocument { body in
            try body.appendElement("p").text("Welcome to the document.")
            try body.appendElement("h1").attr("id", "later").text("Later Section")
            try body.appendElement("p").text("Later content.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 2, "The orphaned content and the later header should each produce their own chunk")
        #expect(texts[0].content.contains("Welcome to the document."), "Without a <title>, the first orphaned piece's text becomes the section's header")
        #expect(texts[1].content.contains("Later Section"))
        #expect(texts[1].content.contains("Later content."))
    }

    @Test("The first orphaned piece still appears as content when a <title> is present")
    func orphanedContentWithTitleKeepsFirstPiece() async throws {
        let document = try makeDocument { body in
            try body.appendElement("p").text("Welcome to the document.")
            try body.appendElement("p").text("A second orphaned paragraph.")
            try body.appendElement("h1").attr("id", "later").text("Later Section")
        }
        try document.head()?.appendElement("title").text("My Document")

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.first?.content.contains("Welcome to the document.") == true, "The first orphaned paragraph's text should still appear as content even when a <title> supplies the header text")
        #expect(texts.first?.content.contains("A second orphaned paragraph.") == true)
    }

    @Test("A single piece larger than contextSize is split by SentenceChunker, with the header prefix embedded in every sub-chunk")
    func oversizedPieceIsSplitWithPrefix() async throws {
        let sentence = "This is one sentence in a very long paragraph that keeps going. "
        let longText = String(repeating: sentence, count: 40)

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "wall-of-text").text("Wall of Text")
            try body.appendElement("p").text(longText)
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 200)
        let texts = textChunks(in: digest)

        #expect(texts.count > 1, "Test precondition: the paragraph should be too large to fit in a single 200-character chunk")

        for chunk in texts {
            #expect(chunk.content.contains("Wall of Text"), "Every sub-chunk produced by SentenceChunker should still carry the section's header prefix")
        }
    }

    @Test("Several small pieces that together exceed contextSize are packed into multiple chunks, each carrying the header prefix")
    func binPackedChunksAllCarryHeaderPrefix() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "notes").text("Notes")
            for index in 1...10 {
                try body.appendElement("p").text("This is note number \(index), and it takes up a bit of space on its own.")
            }
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 150)
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
    func noTrailingEmptyChunkAfterOversizedLastPiece() async throws {
        let sentence = "This is one sentence in a very long paragraph that keeps going. "
        let longText = String(repeating: sentence, count: 40)

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "mixed").text("Mixed Section")
            try body.appendElement("p").text("A short piece first.")
            try body.appendElement("p").text(longText) // oversized, and the LAST piece in the section
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 200)
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
    func imagesAreNotYetEmitted() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "photo.png").attr("alt", "A photo")
            try body.appendElement("p").text("Caption text.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)

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
    func textAroundInlineImageIsPreserved() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            let paragraph = try body.appendElement("p")
            try paragraph.appendText("Before the image.")
            try paragraph.appendElement("img").attr("src", "icon.png").attr("alt", "an icon")
            try paragraph.appendText("After the image.")
        }
        
        try writeTestImage(name: "icon.png")

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)
        let images = imageChunks(in: digest)

        #expect(texts.count == 2)
        
        let beforeImage = try #require(texts.first?.content)
        #expect(beforeImage.contains("Before the image."))
        
        let afterImage = try #require(texts.last?.content)
        #expect(afterImage.contains("After the image."))
        
        #expect(images.count == 1)
        #expect(images.first?.caption == "an icon")
    }

    @Test("A <figure> wrapping an image and caption is attributed to the currently active section")
    func figureContentAttributedToActiveSection() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            let figure = try body.appendElement("figure")
            try figure.appendElement("img").attr("src", "photo.png").attr("alt", "a photo")
            try figure.appendElement("figcaption").text("Figure 1: A nice photo.")
            try body.appendElement("h1").attr("id", "closing").text("Closing")
            try body.appendElement("p").text("The end.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 2, "Exactly two sections should be produced: Gallery and Closing")

        let galleryChunk = try #require(texts.first { $0.content.contains("Gallery") })
        #expect(galleryChunk.content.contains("Figure 1: A nice photo."), "The figcaption should be attributed to the Gallery section, not dropped or misplaced")

        let closingChunk = try #require(texts.first { $0.content.contains("Closing") })
        #expect(!closingChunk.content.contains("Figure 1"), "The figure's caption should not leak into a later section")
    }

    @Test("Loose text with no wrapping tag at all is still captured, not silently dropped")
    func looseTopLevelTextIsCaptured() async throws {
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "notes").text("Notes")
            try body.appendText("A stray sentence with no wrapping tag at all.")
            try body.appendElement("p").text("A normal wrapped paragraph.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        #expect(texts.count == 1)
        #expect(texts.first?.content.contains("A stray sentence with no wrapping tag at all.") == true)
        #expect(texts.first?.content.contains("A normal wrapped paragraph.") == true)
    }

    @Test("Whitespace-only text between elements does not produce spurious extra pieces")
    func whitespaceOnlyTextIsIgnored() async throws {
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
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
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

    // MARK: - Image Loading
    //
    // ImageDecoder does a real network fetch for any non-file:// src, so these tests only ever
    // reference locally-written images — no test here should depend on network access.

    @Test("A locally-resolvable image is loaded and emitted as image content")
    func localImageIsLoaded() async throws {
        try writeTestImage(name: "photo.png")

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "photo.png").attr("alt", "A test photo")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let images = imageChunks(in: digest)

        #expect(images.count == 1)
        #expect(images.first?.caption == "A test photo")
        #expect(images.first?.content.isEmpty == false)

        guard case .selector = images.first?.location.anchor else {
            Issue.record("Image chunks should anchor via CSS selector")
            return
        }
    }

    @Test("A missing local image is skipped without failing the whole digest")
    func missingLocalImageIsSkippedGracefully() async throws {
        // Deliberately not writing a file for "does-not-exist.png" — ImageDecoder.loadImage
        // should return nil for it (Data(contentsOf:) fails, caught by `try?`), and digest()
        // should just skip that one piece rather than throwing.
        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "does-not-exist.png").attr("alt", "Missing")
            try body.appendElement("p").text("Caption text that should still be captured.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)

        #expect(imageChunks(in: digest).isEmpty, "A missing local image should be skipped, not crash or produce a bogus image piece")
        #expect(textChunks(in: digest).first?.content.contains("Caption text that should still be captured.") == true, "Text after a failed image load should still be captured")
    }

    @Test("An image with no alt attribute still loads, with a nil caption")
    func imageWithoutAltStillLoads() async throws {
        try writeTestImage(name: "photo.png")

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "photo.png") // no alt attribute at all
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let images = imageChunks(in: digest)

        #expect(images.count == 1)
        #expect(images.first?.caption == nil)
    }

    @Test("Multiple images in one document all load, each with their own caption")
    func multipleImagesAreLoaded() async throws {
        try writeTestImage(name: "one.png")
        try writeTestImage(name: "two.png")
        try writeTestImage(name: "three.png")

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("img").attr("src", "one.png").attr("alt", "One")
            try body.appendElement("img").attr("src", "two.png").attr("alt", "Two")
            try body.appendElement("img").attr("src", "three.png").attr("alt", "Three")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let images = imageChunks(in: digest)

        #expect(images.count == 3)
        #expect(Set(images.map(\.caption)) == ["One", "Two", "Three"])

        // No text chunks exist in this document at all (only images), so sequencing happens to
        // land as a contiguous 0..<3 here — see documentLengthCountsTextAndImagesTogether below
        // for why that's not true in general once real text chunks are also present.
        let sequenceIndices = images.map { $0.location.sequenceIndex }.sorted()
        #expect(sequenceIndices == Array(0..<images.count))
    }

    @Test("Text before and after an image is split into separate chunks around it")
    func textAroundImageIsSplitIntoSeparateChunks() async throws {
        try writeTestImage(name: "photo.png")

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("p").text("Before the image.")
            try body.appendElement("img").attr("src", "photo.png").attr("alt", "A photo")
            try body.appendElement("p").text("After the image.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)
        let images = imageChunks(in: digest)

        #expect(images.count == 1)
        #expect(texts.count == 2, "The image should split the section's text into a chunk before it and a chunk after it")
        #expect(texts.first?.content.contains("Before the image.") == true)
        #expect(texts.last?.content.contains("After the image.") == true)
    }

    @Test("documentLength reflects the total combined count of text and image chunks, not per-type counts")
    func documentLengthCountsTextAndImagesTogether() async throws {
        try writeTestImage(name: "photo.png")

        let document = try makeDocument { body in
            try body.appendElement("h1").attr("id", "gallery").text("Gallery")
            try body.appendElement("p").text("Before the image.")
            try body.appendElement("img").attr("src", "photo.png").attr("alt", "A photo")
            try body.appendElement("p").text("After the image.")
        }

        let fileURL = try write(document)
        let digest = try await digestor.digest(file: fileURL, contextSize: 10_000)

        // Unlike PDFDigester (which numbers text and image chunks in two independent 0..<N
        // spaces, each reconciled to its own count), HTMLandXMLDigester shares one sequenceIndex
        // counter across everything in digest() and reconciles every chunk's documentLength to
        // that same final total — so an image chunk's documentLength here reflects ALL chunks
        // (text + image) combined, not the image count alone.
        #expect(digest.count == 3, "Test precondition: 2 text chunks (before/after) + 1 image chunk")
        for piece in digest {
            #expect(piece.location.documentLength == 3)
        }
    }
}
