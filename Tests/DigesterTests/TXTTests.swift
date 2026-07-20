//
//  TxtTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//  Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
//

import Testing
@testable import Digester
import Foundation

struct TXTTests {
    @Test("Ensure txt digester reproduces the full content of a file that fits within a single chunk", arguments: [
        Bundle.module.url(forResource: "Sonnet-149", withExtension: "txt", subdirectory: "Test Documents/Sonnets")!
    ]) func testTXTDigesterSmallFile(txtFile: URL) throws {
        let digestor = TXTDigester()
        let digest = try digestor.digest(file: txtFile, contextSize: 10000)
        
        let expectedContent = try String(contentsOf: txtFile, encoding: .utf8)
        
        // A file smaller than contextSize should still be returned as one whole-document chunk.
        #expect(digest.count == 1, "A file smaller than contextSize should produce exactly one chunk")
        
        guard case let .text(content, location) = digest.first else {
            #expect(Bool(false), "Digest should be a text digest")
            return
        }
        
        #expect(content == expectedContent, "The single chunk should contain the file's entire content")
        
        guard case let .text(characterRange) = location.anchor else {
            #expect(Bool(false), "Digest location should anchor to a text character range")
            return
        }
        #expect(characterRange == 0..<expectedContent.count, "The chunk's range should span the entire document")
    }
    
    @Test("Ensure txt digester splits large files into multiple sequential, non-empty chunks", arguments: [
        Bundle.module.url(forResource: "Shakespeare", withExtension: "txt", subdirectory: "Test Documents/txt")!
    ]) func testTXTDigesterLargeFile(txtFile: URL) throws {
        let digestor = TXTDigester()
        let digest = try digestor.digest(file: txtFile, contextSize: 2000)
        
        #expect(digest.count > 1, "A file much larger than contextSize should be split into multiple chunks")
        
        for (offset, piece) in digest.enumerated() {
            guard case let .text(content, location) = piece else {
                #expect(Bool(false), "Every piece from the txt digester should be text")
                continue
            }
            
            #expect(!content.isEmpty, "No chunk should be empty")
            #expect(location.sequenceIndex == offset, "Chunks should be sequenced in document order")
            #expect(location.documentLength == digest.count, "documentLength should match the actual number of returned chunks")
        }
    }
}
