//
//  HTMLDigester.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation
import SwiftSoup

/// A builder that is passed through recursive calls of ``HTMLandXMLDigester/walk(_:builder:)``.
fileprivate final class SectionBuilder {
    private(set) var sections: [HTMLandXMLDigester.Section] = []
    private(set) var orphaned: [HTMLandXMLDigester.ContentPiece] = []
    
    /// Adds a new section to the sections list.
    /// - Parameter section: The section to append.
    func addSection(_ section: HTMLandXMLDigester.Section) {
        sections.append(section)
    }
    
    /// Appends a content piece into either the orphaned list or the most recent section.
    ///
    /// A content piece is orphaned if there is no current section for it to be added to.
    /// - Parameter content: The content to insert into the builder.
    func append(_ content: HTMLandXMLDigester.ContentPiece) {
        if !sections.isEmpty {
            let lastIndex = sections.index(before: sections.endIndex)
            sections[lastIndex].pieces.append(content)
        } else {
            orphaned.append(content)
        }
    }
}

final class HTMLandXMLDigester: FileDigester {
    /// A piece of HTML or XML content. Either text or image, with a mandatory selector to
    /// reference the Content's place in the document.
    enum ContentPiece {
        case text(text: String, selector: String)
        case image(src: String, alt: String?, selector: String)
        
        var text: String {
            switch self {
            case .text(let text, _):
                return text
            case .image(let src, let alt, _):
                return alt ?? src
            }
        }
        
        var selector: String {
            switch self {
            case .text(_, let selector):
                return selector
            case .image(_, _, let selector):
                return selector
            }
        }
    }
    
    /// A section of content containing a header and the pieces within.
    struct Section: Sendable {
        let headerText: String
        let headerSelector: String
        var pieces: [ContentPiece] = []
    }
    
    /// File types supported by the HTMl and XML Digester
    ///
    /// # Custom Types
    /// | Description | UTI | Extensions | Conforms to | MIME types | Reference |
    /// | --- | --- | --- | --- | --- | --- |
    /// | OPML document | org.opml.opml | .opml | public.xml | text/xml, text/x-opml, application/xml | https://opml.org/spec2.opml |
    static let fileTypes: [UTType] = [ .html, .xml, .xmlPropertyList, UTType(importedAs: "org.opml.opml", conformingTo: .xml) ]
    
    static let headerTags: [String] = ["h1", "h2", "h3", "h4", "h5", "h6"]

    required init() { }
    
    /// Digest an HTML or XML file, and convert it into `EmbeddableContent`.
    /// - Parameters:
    ///   - file: The HTML or XML file to convert.
    ///   - contextSize: The size of embeddable content chunks to return.
    /// - Returns: An array of `EmbeddableContent` that represents the DOM of the provided document.
    func digest(file: URL, contextSize: Int) async throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try HTMLandXMLDigester.validateLocalURL(file)
        
        // Will automatically select HTML or XML based on file contents
        let document: Document = try SwiftSoup.parse(file)
        
        // Start at the document body, if there is non start at the document root.
        let root = document.body() ?? document
        
        let builder: SectionBuilder = SectionBuilder()
        
        try walk(root, builder: builder)
        
        var sections = builder.sections
        
        // Orphaned items are added into their own block at the top of the document, since they happen before the first Header Tag appears.
        if !builder.orphaned.isEmpty, let rootSelector = try? root.cssSelector() {
            let title = (try? document.title()) ?? builder.orphaned.first?.text ?? "No Header"
            
            let orphanedSection = Section(headerText: title, headerSelector: rootSelector, pieces: builder.orphaned)
            sections.insert(orphanedSection, at: 0)
        }
        
        // Process sections into embeddable content
        var chunks: [EmbeddableContent] = []
        var sequenceIndex: Int = 0

        for section in sections {
            // Start off with the section header & its selector to provide positioning info to LLMs. See: https://www.anthropic.com/engineering/contextual-retrieval
            let headerPrefix: String = "\(section.headerText): (\(section.headerSelector))\n\n"
            var currentChunkText = headerPrefix
            var currentChunkSelectors: [String] = []
            var currentChunkHasContent: Bool = false
            
            func finishTextChunk() {
                // Make sure we have added content to the chunk. We can't just do a simple text is empty since the header is always present in the chunk text.
                guard currentChunkHasContent else {
                    Log.logger.warning("Finished chunk called without any chunk content.")
                    return
                }
                let documentLocation = DocumentLocation(sequenceIndex: sequenceIndex, documentLength: -1, anchor: .selector(selectors: currentChunkSelectors))
                chunks.append(.text(content: currentChunkText, location: documentLocation))
                
                sequenceIndex += 1
                currentChunkText = headerPrefix
                currentChunkSelectors.removeAll()
                currentChunkHasContent = false
            }
            
            for piece in section.pieces {
                switch piece {
                case .text(let text, let selector):
                    if text.count > contextSize {
                        finishTextChunk()
                        
                        let pieceChunks = SentenceChunker.chunkContent(for: text, contextSize: contextSize, prefix: headerPrefix, sequenceOffset: sequenceIndex) { _ in
                            .selector(selectors: [selector])
                        }
                        
                        chunks.append(contentsOf: pieceChunks)
                        sequenceIndex += pieceChunks.count
                        continue
                    }
                    
                    // If this text will push us over the context size, finish the chunk and start a new one.
                    if currentChunkHasContent, currentChunkText.count + text.count > contextSize {
                        finishTextChunk()
                    }
                    
                    // Append to current chunk
                    currentChunkText += text
                    currentChunkSelectors.append(selector)
                    currentChunkHasContent = true
                case .image(let src, let alt, let selector):
                    // Stop the current text chunk because it was interrupted by an image.
                    finishTextChunk()
                    
                    do {
                        let imageData = try await ImageDecoder().loadImage(src: src, relativeTo: file)
                        let documentLocation = DocumentLocation(sequenceIndex: sequenceIndex, documentLength: -1, anchor: .selector(selectors: [selector]))
                        sequenceIndex += 1
                        chunks.append(.image(content: imageData, caption: alt, location: documentLocation))
                    } catch {
                        Log.logger.error("Failed to decode image \(src)", error: error)
                        continue
                    }
                }
            }
            
            // If there is a text chunk sitting around
            if !currentChunkText.isEmpty {
                finishTextChunk()
            }
        }
        
        // Update the document length for all of the chunks.
        for index in chunks.indices {
            chunks[index] = chunks[index].withNewDocumentLength(length: sequenceIndex)
        }
        
        return chunks
    }
    
    /// Walk the DOM and create header based sections.
    ///
    /// If content is found outside of a header, it is processed as an Orphan.
    /// - Parameters:
    ///   - element: The element to walk the child tree of
    ///   - builder: A builder reference to create sections in. Provides consistent access to the same sections for recursive walk calls.
    private func walk(_ element: Element, builder: SectionBuilder) throws  {
        // The overall element selector, used for stray nodes.
        let elementSelector = try element.cssSelector()
        
        for node in element.getChildNodes() {
            // Collect any loose text that is directly under the `element`
            if let textNode = node as? TextNode {
                guard !textNode.isBlank() else { continue }
                // Use the parent element's selector since nodes have no selector.
                builder.append(.text(text: textNode.text(), selector: elementSelector))
                continue
            }
            
            // The rest of this function deals with actual structured HTML content, and not loose nodes.
            guard let child = node as? Element else { continue }
            let tag = child.tagName()
            let selector = try child.cssSelector()
            
            if HTMLandXMLDigester.headerTags.contains(tag) {
                let headerText = try child.text()
                guard !headerText.isEmpty else { continue }
                builder.addSection(Section(headerText: headerText, headerSelector: selector))
                continue // Jump Loop
            }
            
            // Load a table
            if tag == "table" {
                let tableText = try renderTable(child)
                guard !tableText.isEmpty else {
                    Log.logger.warning("Table text returned as empty")
                    continue
                }
                
                builder.append(.text(text: tableText, selector: selector))
                continue // Done!
            }
            
            // Parse an image, do not load it though.
            if tag == "img" {
                let src = try child.attr("src")
                guard !src.isEmpty else {
                    Log.logger.warning("Table text returned as empty")
                    continue
                }
                let rawAlt = try child.attr("alt")
                // SwiftSoup never returns nil, it will return an empty string. So convert to an optional by checking if the returned attribute is empty.
                let alt = rawAlt.isEmpty ? nil : rawAlt
                
                let contentPiece = ContentPiece.image(src: src, alt: alt, selector: selector)
                
                builder.append(contentPiece)
                continue // Done!
            }
            
            // If the element is a block, we want to walk its content
            if !(try child.select("table, img, h1, h2, h3, h4, h5, h6").isEmpty()) {
                // Recurse into the block
                try walk(child, builder: builder)
                continue // Done!
            }
            
            // If all else fails, append the text of this element.
            let nestedText = try child.text()
            // If nested text, check if there is a "text" attribute from OPML.
            let text = nestedText.isEmpty ? try child.attr("text") : nestedText
            guard !text.isEmpty else { continue }
            builder.append(.text(text: text, selector: selector))
        }
    }
    
    /// Parse a SwiftSoup ``Element`` that has been detected as a "table" tag.
    ///
    /// - Parameter table: Produces a markdown formatted table from an HTML table
    private func renderTable(_ table: Element) throws -> String {
        var tableLines: [String] = []
        
        // Iterate over all of the table rows
        for row in try table.select("tr") {
            let headers = try row.select("th")
            let data = try row.select("td")
            
            // Join headers into a markdown style table header
            if !headers.isEmpty() {
                let headerLabels = headers.compactMap({try? $0.text()})
                let headerLine = headerLabels.joined(separator: " | ").surrounded(by: "|")
                
                // Create a markdown header separator: |---|---|---|
                let separatorLine = Array(repeating: "---", count: headerLabels.count).joined(separator: "|").surrounded(by: "|")
                
                tableLines.append(headerLine)
                tableLines.append(separatorLine)
            }
            
            // Join data into a markdown style table row
            if !data.isEmpty() {
                let dataLine = data.compactMap({try? $0.text()}).joined(separator: " | ").surrounded(by: "|")
                tableLines.append(dataLine)
            }
        }
        
        
        // Append the table's caption to the bottom of the table with emphasis.
        // ref: https://www.markdownguide.org/hacks/#image-captions.
        // If we can't find a caption its not a big deal, so use try?
        if let caption = try? table.select("caption").first(),
           let captionText = try? caption.text(),
           !captionText.isEmpty {
            tableLines.append("*\(captionText)*")
        }
        
        return tableLines.joined(separator: "\n")
    }
}
