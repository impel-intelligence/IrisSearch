//
//  MarkdownChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/4/26.
//

import Foundation
import IrisCommon
import Markdown
import SwiftSoup

enum MarkdownBlock {
    case heading(level: Int, text: String, range: SourceRange)
    case text(content: String, range: SourceRange)
    case image(src: String, alt: String?, range: SourceRange)
    case thematicBreak
}

struct BlockCollector: MarkupWalker {
    private(set) var blocks: [MarkdownBlock] = []
    
    mutating func visitHeading(_ heading: Heading) {
        // Range should always be populated since this walker is only ever walking a parsed document.
        guard let range = heading.range else { return }
        
        // Reconstruct the original header styling for embeddings since they are contextual information
        let shebangs = Array(repeating: "#", count: heading.level).joined(separator: "")
        let text = "\(shebangs) \(heading.plainText)"
        blocks.append(.heading(level: heading.level, text: text, range: range))
    }
    
    mutating func visitImage(_ image: Image) {
        // Range should always be populated since this walker is only ever walking a parsed document.
        guard let range = image.range else { return }
        
        blocks.append(.text(content: image.format(), range: range))
        
        // An image with no source is useless to us.
        guard let source = image.source else { return }
        blocks.append(.image(src: source, alt: image.title, range: range))
    }
    
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        // Tells the chunker to break the chunk and start a new one no matter what.
        blocks.append(.thematicBreak)
    }
    
    mutating func visitParagraph(_ paragraph: Paragraph) {
        // Range should always be populated since this walker is only ever walking a parsed document.
        guard let range = paragraph.range else { return }
        blocks.append(.text(content: paragraph.format(), range: range))
    }
    
    // Edited by Claude Opus 5 (Anthropic) on 2026-08-04
    mutating func defaultVisit(_ markup: any Markup) {
        // `MarkupWalker` implements `defaultVisit` as `descendInto`, so an override has to keep
        // descending itself or the walk stops dead at the first node without a visit method above.
        // Descending *and* collecting would double count, since a container's text would be
        // collected once for the container and again for each child.
        guard !(markup is Markdown.Document),
              let block = markup as? BlockMarkup,
              block.childCount == 0 || block is Table else {
            descendInto(markup)
            return
        }
        
        // Range should always be populated since this walker is only ever walking a parsed document.
        guard let range = block.range else { return }

        // Blocks with nothing to walk into — code blocks, HTML blocks — plus tables, whose
        // markdown only reads correctly whole. Collect their source form rather than descending.
        blocks.append(.text(content: block.format(), range: range))
    }
}

struct MarkdownChunker {
    public static func chunkContent(
        for content: String,
        contextSize: Int,
        sequenceOffset: Int = 0,
//        imageResolver: ((String) async throws -> Data?),
    ) -> [EmbeddableContent] {
        let document = Document(parsing: content)
        var collector = BlockCollector()
        collector.visit(document)
        
        var headerStack: [(level: Int, text: String)] = []
        
        var goodTexts: [(texts: [String], range: RangeSet<SourceLocation>)] = []
        var pendingTexts: [String] = []
        var inProgressTextLength: Int = 0
        var pendingRange: RangeSet<SourceLocation> = RangeSet()
        
        func headerPrefix() -> String {
            return headerStack.map { $0.text.replacingOccurrences(of: "#", with: "") }.joined(separator: " > ")
        }
        
        func flushPending(prefix: String) {
            guard !pendingTexts.isEmpty else { return }
            
            // Insert the header prefix at the beginning of the chunk
            pendingTexts.insert(prefix, at: 0)
            
            // Insert the pending texts and their ranges
            goodTexts.append((pendingTexts, pendingRange))
            
            // Flush everything
            pendingTexts = []
            inProgressTextLength = 0
            pendingRange = RangeSet()
        }

        func insertText(_ text: String, range: SourceRange) {
            let prefix = headerPrefix()
            
            if (inProgressTextLength + text.count) > contextSize - prefix.count {
                // FLush all of the pending text.
                flushPending(prefix: prefix)
            }
            
            pendingRange.insert(contentsOf: range)
            pendingTexts.append(text)
            inProgressTextLength += text.count
        }

        for block in collector.blocks {
            switch block {
            case .heading(let level, let text, let range):
                // Remove any headers with a lower level than this header to clear the stack.
                var didPopStack = false
                while let lastHeader = headerStack.last, lastHeader.level >= level {
                    headerStack.removeLast()
                    didPopStack = true
                }
                
                if didPopStack {
                    // Flush the current text content, will noop if there is no pending text.
                    flushPending(prefix: headerPrefix())
                }
                
                headerStack.append((level, text))
                insertText(text, range: range)
            case .text(let content, let range):
                insertText(content, range: range)
            case .image(let src, let alt, let range):
                break // TODO: Support Markdown Images
            case .thematicBreak:
                flushPending(prefix: headerPrefix())
            }
        }
        
        flushPending(prefix: headerPrefix())
        
        var chunkIndex = sequenceOffset
        
        var textContent: [EmbeddableContent] = []
        
        for (offset, chunk) in goodTexts.enumerated() {
            // Use trim from SwiftSoup since it is faster than standard swift
            let content = chunk.texts.joined(separator: "\n").trim()
            let allRanges = chunk.range.ranges
            let locationOrder = { (a: SourceLocation, b: SourceLocation) -> Bool in
                a.line == b.line ? a.column < b.column : a.line < b.line
            }
            guard let minLoc = allRanges.map(\.lowerBound).min(by: locationOrder),
                  let maxLoc = allRanges.map(\.upperBound).max(by: locationOrder) else {
                continue
            }
            let textRange = TextLocation(line: minLoc.line, column: minLoc.column)..<TextLocation(line: maxLoc.line, column: maxLoc.column)
            let anchor = DocumentAnchor.location(textRange: textRange)
            let location = DocumentLocation(sequenceIndex: sequenceOffset + offset, documentLength: chunkIndex, anchor: anchor)
            textContent.append(EmbeddableContent.text(content: content, location: location))
            chunkIndex += 1
        }
        
        for index in textContent.indices {
            textContent[index] = textContent[index].withNewDocumentLength(length: textContent.count)
        }
        
        return textContent
    }
}
