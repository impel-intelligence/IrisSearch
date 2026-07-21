//
//  XMLDigesterConstructedTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-20.
//
//  The XML/OPML counterpart to HTMLDigesterConstructedTests.swift. Every document here is built
//  via SwiftSoup's XML parser/builder API (Parser.xmlParser(), appendElement/attr/text) and
//  written to a `.xml` file in a per-test temporary directory that is torn down afterward.
//  HTMLandXMLDigester.digest() parses with `SwiftSoup.parse(file)`, which auto-detects HTML vs.
//  XML from a leading `<?xml ... ?>` declaration — these tests exercise that XML path, since
//  every existing test elsewhere only ever fed it `.html` content.

import Testing
@testable import Digester
import SwiftSoup
import IrisCommon
import Foundation

final class XMLDigesterConstructedTests {
    private let digestor = HTMLandXMLDigester()
    private let workingDirectory: URL

    init() {
        workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("XMLDigesterConstructedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// Builds a blank XML document (with a leading `<?xml?>` declaration, parsed via
    /// `Parser.xmlParser()`) with the given root tag, and hands that root element to `build` for
    /// populating via SwiftSoup's element-builder API.
    private func makeXMLDocument(root rootTag: String, _ build: (Element) throws -> Void) throws -> Document {
        let document = try SwiftSoup.parse("<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(rootTag)></\(rootTag)>", "", Parser.xmlParser())
        let root = try #require(document.children().first())
        try build(root)
        return document
    }

    /// Serializes `document` and writes it to a fresh `.xml` file inside this test's temporary working directory.
    private func write(_ document: Document) throws -> URL {
        let fileURL = workingDirectory.appendingPathComponent("\(UUID().uuidString).xml")
        let xml = try document.outerHtml()
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func textChunks(in digest: [EmbeddableContent]) -> [(content: String, location: DocumentLocation)] {
        return digest.compactMap { piece in
            guard case let .text(content, location) = piece else { return nil }
            return (content, location)
        }
    }

    private func allText(in digest: [EmbeddableContent]) -> String {
        return textChunks(in: digest).map(\.content).joined(separator: "\n")
    }

    @Test("Generic XML with no HTML-like tags still has its text captured")
    func genericXMLIsCaptured() throws {
        // <catalog> has no <body> tag anywhere, so digest() falls back to walking the whole
        // document; none of <catalog>/<item>/<name>/<price> are header/table/img or contain one,
        // so the entire tree is captured as a single leaf via .text().
        let document = try makeXMLDocument(root: "catalog") { catalog in
            let item1 = try catalog.appendElement("item")
            try item1.appendElement("name").text("Widget")
            try item1.appendElement("price").text("9.99")

            let item2 = try catalog.appendElement("item")
            try item2.appendElement("name").text("Gadget")
            try item2.appendElement("price").text("19.99")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let combined = allText(in: digest)

        #expect(combined.contains("Widget"))
        #expect(combined.contains("9.99"))
        #expect(combined.contains("Gadget"))
        #expect(combined.contains("19.99"))
    }

    @Test("Custom XML using h1/h2-named tags still gets header-based sectioning, proving tag matching is format-agnostic")
    func headerLikeTagsSectionXMLToo() throws {
        // No <body> tag exists, so digest() walks <document> itself. <document> isn't a header,
        // but it *contains* <h1>/<h2>, so walk() recurses into it and finds them exactly the way
        // it would find <h1>/<h2> inside an HTML <div> wrapper.
        let document = try makeXMLDocument(root: "document") { root in
            try root.appendElement("h1").attr("id", "chapter-one").text("Chapter One")
            try root.appendElement("p").text("Chapter one content.")
            try root.appendElement("h2").attr("id", "section-1-1").text("Section 1.1")
            try root.appendElement("p").text("Subsection content.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let texts = textChunks(in: digest)

        let chapterChunk = try #require(texts.first { $0.content.contains("Chapter One") })
        #expect(chapterChunk.content.contains("Chapter one content."))
        #expect(!chapterChunk.content.contains("Subsection content."), "Chapter One's chunk should not include Section 1.1's content")

        let sectionChunk = try #require(texts.first { $0.content.contains("Section 1.1") })
        #expect(sectionChunk.content.contains("Subsection content."))
    }

    @Test("XML content stored in nested element text (plist-style) is captured correctly")
    func elementTextBasedXMLIsCaptured() throws {
        // Contrast case for the OPML test below: when an XML format stores its data as nested
        // element *text* (like Apple's XML plist <string>/<integer> elements) rather than in
        // attributes, walk()'s .text()-based leaf capture works exactly as it does for HTML.
        let document = try makeXMLDocument(root: "plist") { plist in
            let dict = try plist.appendElement("dict")
            try dict.appendElement("key").text("Name")
            try dict.appendElement("string").text("Widget")
            try dict.appendElement("key").text("Price")
            try dict.appendElement("string").text("9.99")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let combined = allText(in: digest)

        #expect(combined.contains("Name"))
        #expect(combined.contains("Widget"))
        #expect(combined.contains("Price"))
        #expect(combined.contains("9.99"))
    }

    // OPML (one of HTMLandXMLDigester's declared `fileTypes`) stores each entry's actual content
    // in the `text` attribute of a normally-empty `<outline>` element — e.g.
    // `<outline text="Tech News" type="rss" xmlUrl="..." />` — not as nested text nodes. OPML's
    // <body> tag *is* found (Document.body() is a plain tag-name search, so it works the same
    // for XML as it does for HTML), and walk() correctly reaches each <outline> as a leaf. Its
    // leaf-capture path calls `child.text()` first (nested text, the common case for HTML/XML)
    // and falls back to the `text` attribute only when that's empty — which is exactly the case
    // for a self-closed <outline>, so its `text` attribute is what ends up captured.
    @Test("OPML outline entries (text stored in the `text` attribute) are captured")
    func opmlOutlineTextIsCaptured() throws {
        let document = try makeXMLDocument(root: "opml") { opml in
            try opml.attr("version", "2.0")

            let head = try opml.appendElement("head")
            try head.appendElement("title").text("My Podcasts")

            let body = try opml.appendElement("body")
            try body.appendElement("outline")
                .attr("text", "Tech News")
                .attr("type", "rss")
                .attr("xmlUrl", "https://example.com/feed1.xml")
            try body.appendElement("outline")
                .attr("text", "Daily Digest")
                .attr("type", "rss")
                .attr("xmlUrl", "https://example.com/feed2.xml")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let combined = allText(in: digest)

        #expect(combined.contains("Tech News"))
        #expect(combined.contains("Daily Digest"))
    }

    // walk()'s node-level iteration (walking every child node, not just child Elements) is shared
    // code, not HTML-specific — confirm loose text beside a structural element is captured here too.
    @Test("Loose text directly beside a header-like tag in XML is still captured, not just the tag's own text")
    func looseTextBesideHeaderLikeTagIsCaptured() throws {
        let document = try makeXMLDocument(root: "document") { root in
            try root.appendElement("h1").attr("id", "chapter-one").text("Chapter One")
            let wrapper = try root.appendElement("section")
            try wrapper.appendText("Leading note: ")
            try wrapper.appendElement("h2").attr("id", "sub").text("Sub Point")
            try wrapper.appendText(" trailing note.")
        }

        let fileURL = try write(document)
        let digest = try digestor.digest(file: fileURL, contextSize: 10_000)
        let combined = allText(in: digest)

        #expect(combined.contains("Chapter One"))
        #expect(combined.contains("Sub Point"))
        #expect(combined.contains("Leading note:"))
        #expect(combined.contains("trailing note."))
    }
}
