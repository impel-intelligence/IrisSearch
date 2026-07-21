//
//  HTMLandXMLTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import Testing
@testable import Digester
import IrisCommon
import Foundation
import SwiftSoup

func printNodeTree(node: Node, indent: Int = 0) {
    let indentation = String(repeating: "  ", count: indent)
    
    // Check if the node is an Element (has tags) vs a TextNode
    if let element = node as? Element {
        print("\(indentation)<\(element.tagName())>")
    } else {
        let cleanText = node.nodeName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanText.isEmpty {
            print("\(indentation)\(cleanText)")
        }
    }
    
    // Recursively print children
    for child in node.getChildNodes() {
        printNodeTree(node: child, indent: indent + 1)
    }
}


struct HTMLandXMLTests {
    @Test("Every header in headers.html produces its own anchored text chunk, in document order")
    func testHeaderSections() throws {
        let htmlFile = Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
        let digestor = HTMLandXMLDigester()
        let digest = try digestor.digest(file: htmlFile, contextSize: 1000)
            
        var validHeaders = ["Header 1", "Header 1a", "Header 2", "Header 2a", "Header 2b", "Header 2c", "Header 2d", "Header 2e", "Long Header"]
    
        for content in digest {
            guard let header = validHeaders.first else { continue }
            // Every piece should be a text piece in this document
            try #require(content.textContent != nil, "Every piece should be a text piece in this document")
            
            #expect(!content.textContent!.isEmpty, "Content should not be empty.")
            
            if content.textContent!.contains(header) {
                validHeaders.removeFirst()
            }
        }
        
        #expect(validHeaders.isEmpty, "Every header should have appearedin the returned content.")
    }
}
