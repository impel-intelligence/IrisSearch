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

final class HTMLandXMLDigester: FileDigester {
    struct IndexedElement: Hashable {
        let index: Int
        let element: Element
    }
    
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
    
    struct Section {
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
    
    func digest(file: URL, contextSize: Int) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try HTMLandXMLDigester.validateLocalURL(file)
        
        // Will automatically select HTML or XML based on file contents
        let document: Document = try SwiftSoup.parse(file)
        
        // Start at the document body, if there is non start at the document root.
        let root = document.body() ?? document
        
        var (sections, orphaned) = try walk(root)
        
        // Orphaned items are added into their own block at the top of the document, since they happen before the first Header Tag appears.
        if !orphaned.isEmpty, let rootSelector = try? root.cssSelector() {
            let firstOrphan = orphaned.removeFirst()
            let title = (try? document.title()) ?? firstOrphan.text
            
            let orphanedSection = Section(headerText: title, headerSelector: rootSelector, pieces: orphaned)
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
                guard currentChunkHasContent else { return }
                let documentLocation = DocumentLocation(sequenceIndex: sequenceIndex, documentLength: -1, anchor: .selector(selectors: currentChunkSelectors))
                chunks.append(.text(content: currentChunkText, location: documentLocation))
                
                sequenceIndex += 1
                currentChunkText = headerPrefix
                currentChunkSelectors.removeAll()
                currentChunkHasContent = true
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
                    // Stop the current text chunk
                    // TODO: Add support for image loading
                    break
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
            print(chunks[index])
        }
        
        return chunks
    }
    
    private func walk(_ element: Element) throws -> (sections: [Section], orphaned: [ContentPiece]) {
        var sections: [Section] = []
        var orphaned: [ContentPiece] = []
        
        func append(_ content: ContentPiece) {
            if !sections.isEmpty {
                let lastIndex = sections.index(before: sections.endIndex)
                sections[lastIndex].pieces.append(content)
            } else {
                orphaned.append(content)
            }
        }
        
        for child in element.children() {
            let tag = child.tagName()
            let selector = try child.cssSelector()
            
            if HTMLandXMLDigester.headerTags.contains(tag) {
                let headerText = try child.text()
                guard !headerText.isEmpty else { continue }
                sections.append(Section(headerText: headerText, headerSelector: selector))
                continue // Jump Loop
            }
            
            // Load a table
            if tag == "table" {
                let tableText = try renderTable(child)
                guard !tableText.isEmpty else { continue }
                
                append(.text(text: tableText, selector: selector))
                continue // Done!
            }
            
            // Parse an image, do not load it though.
            if tag == "img" {
                let src = try child.attr("src")
                guard !src.isEmpty else { continue }
                let alt = try child.attr("alt")
                
                let contentPiece = ContentPiece.image(src: src, alt: alt, selector: selector)
                
                append(contentPiece)
                continue // Done!
            }
            
            // If the element is a block, we want to walk its content
            if !(try child.select("table, img, h1, h2, h3, h4, h5, h6").isEmpty()) {
                let (childSections, childOrphans) = try walk(child)
                
                // Combining sections requires us to combine headers that have the same selector. This is purely defensive, as a header with the same selector should never appear as a child of itself.
                sections = combineSections(sections, rhs: childSections)
                orphaned.append(contentsOf: childOrphans)
                continue // Done!
            }
            
            // If all else fails, append the text of this element.
            let text = try child.text()
            guard !text.isEmpty else { continue }
            append(.text(text: text, selector: selector))
        }
        
        return (sections, orphaned)
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
    
    private func combineSections(_ lhs: [Section], rhs: [Section]) -> [Section] {
        var combined = lhs

        for rightSection in rhs {
            if let index = combined.firstIndex(where: { $0.headerSelector == rightSection.headerSelector }) {
                combined[index].pieces.append(contentsOf: rightSection.pieces)
            } else {
                combined.append(rightSection)
            }
        }

        return combined
    }
    
//    private func loadImage(from piece: ContentPiece, relativeTo file: URL) throws -> Data? {
//        guard case .image(let src, let alt, let selector) = piece else { return nil }
//
//        guard let url = URL(string: src, relativeTo: file) else { return nil }
//        
//    }
}
