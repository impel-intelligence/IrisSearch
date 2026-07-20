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
    
    /// File types supported by the HTMl and XML Digester
    ///
    /// # Custom Types
    /// | Description | UTI | Extensions | Conforms to | MIME types | Reference |
    /// | --- | --- | --- | --- | --- | --- |
    /// | OPML document | org.opml.opml | .opml | public.xml | text/xml, text/x-opml, application/xml | https://opml.org/spec2.opml |
    static let fileTypes: [UTType] = [ .html, .xml, .xmlPropertyList, UTType(importedAs: "org.opml.opml", conformingTo: .xml) ]
    
    static let headers: [String] = ["h1", "h2", "h3", "h4", "h5", "h6"]

    required init() { }
    
    func collectHeaders(in element: Element, index: Int) throws -> (headers: [IndexedElement: [IndexedElement]], orphans: [IndexedElement]) {
        var orphaned: [IndexedElement] = []
        var headers: [IndexedElement: [IndexedElement]] = [:]
        var currentHeader: IndexedElement? = nil
        
        var currentIndex = index
        
        for child in element.children()  {
            let indexed = IndexedElement(index: currentIndex, element: child)
            currentIndex += 1
            
            // If we are a header, start a new header
            if HTMLandXMLDigester.headers.contains(child.tagName()) {
                headers[indexed] = []
                currentHeader = indexed
                continue // Skip loop
            }
            
            if let currentHeader {
                headers[currentHeader, default: []].append(indexed)
            } else {
                orphaned.append(indexed)
            }
        }
        
        return (headers, orphaned)
    }
    
    func digest(file: URL, contextSize: Int) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try HTMLandXMLDigester.validateLocalURL(file)
        
        let document: Document = try SwiftSoup.parse(file)

        let (headers, orphaned) = try collectHeaders(in: document, index: 0)
        
        let documentLength = headers.values.map(\.count).reduce(0, +) + orphaned.count
        
        var embeddableContent: [EmbeddableContent] = []
        
        for indexed in orphaned {
            let element = indexed.element
            
            let text = try element.text()
            let selector = try element.cssSelector()
            let anchor = DocumentAnchor.selector(selectors: [selector])
            
            let content = EmbeddableContent.text(
                content: text,
                location: DocumentLocation(sequenceIndex: indexed.index, documentLength: documentLength, anchor: anchor)
            )
            
            embeddableContent.append(content)
        }
        
        
        
        
        
        return SentenceChunker.chunkContent(for: "", contextSize: contextSize) { range in
            return .text(characterRange: range)
        }
    }
}
