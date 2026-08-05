//
//  MarkdownChunkerTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/4/26.
//

import Testing
@testable import Digester
import IrisCommon
import Foundation

struct MarkdownChunkerTests {
    @Test func testHeaderGrouping() throws {
        let markdown = """
            # Header 1
            ## Header 2
            ### Header 3
            # Header 1
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        #expect(chunks.count == 2, "There should be two chunks")
        let lastChunk = try #require(chunks.last)
        
        #expect(lastChunk.location.documentLength == 2, "The document length should be 2")
        #expect(lastChunk.location.sequenceIndex == 1, "There lat sequence should be 1, since it is 0 indexed.")
    }
    
    @Test func testTable() throws {
        let markdown = """
            | Syntax      | Description |
            | ----------- | ----------- |
            | Header      | Title       |
            | Paragraph   | Text        |
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()
        
        #expect(textContent.contains("Syntax"))
        #expect(textContent.contains("Description"))
        #expect(textContent.contains("Header"))
        #expect(textContent.contains("Title"))
        #expect(textContent.contains("Paragraph"))
        #expect(textContent.contains("Text"))
    }

    @Test func testCode() throws {
        let markdown = """
            ```swift
            let chunks = await MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
            let textContent = chunks.compactMap { $0.textContent }.joined()
            ```
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()

        #expect(textContent.contains("swift"))
        #expect(textContent.contains("let chunks"))
        #expect(textContent.contains("let textContent"))
    }
    
    @Test func testLink() throws {
        let markdown = """
            [Hello World](hello.png)
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()

        #expect(textContent.contains("hello.png"))
        #expect(textContent.contains("Hello World"))
    }

    @Test func testImage() throws {
        let markdown = """
            ![Hello World](hello.png)
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()

        #expect(textContent.contains("hello.png"))
        #expect(textContent.contains("Hello World"))
    }

    @Test func testHTML() throws {
        let markdown = """
            <div class="footer">
                &copy; 2004 Foo Corporation
            </div>
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()

        #expect(textContent.contains("class="))
        #expect(textContent.contains("&copy"))
    }
    
    @Test func testEmphasisAndBold() throws {
        let markdown = """
            *single asterisks*

            _single underscores_

            **double asterisks**

            __double underscores__
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()
        
        #expect(textContent.contains("*single asterisks*"))
        #expect(!textContent.contains("_single underscores_"), "Underscores should be normalized to asterisks")
        #expect(textContent.contains("**double asterisks**"))
        #expect(!textContent.contains("__double underscores__"), "Underscores should be normalized to asterisks")
    }

    @Test func testParagraph() throws {
        let markdown = """
            # Header
            This is a normal piece of tex that should be recognized as a paragraph.
            
            ## Header Two
            This is a second level header.
            """
        
        let chunks = MarkdownChunker.chunkContent(for: markdown, contextSize: 512)
        let textContent = chunks.compactMap { $0.textContent }.joined()
        
        #expect(textContent.contains("This is a normal piece of tex that should be recognized as a paragraph."))
    }
}
