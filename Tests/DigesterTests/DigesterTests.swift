//
//  DigesterTests.swift
//  DigesterTests
//
//  by Taylor Lineman on 6/10/26.
//

import Testing
@testable import Digester
import Foundation

@Test("Ensure txt digester can read files", arguments: [
    Bundle.module.url(forResource: "Shakespeare", withExtension: "txt", subdirectory: "Test Documents/txt")!
]) func testTXTDigester(txtFile: URL) throws {
    let digestor = TXTDigester()
    let digest = try digestor.digest(file: txtFile)
    
    // Txt digester should always produce one piece, with the content of the entire file.
    #expect(digest.count == 1, "Txt digest should produce one piece.")
    
    // Freaky swift code to unwrap the enum
    guard case let .text(content) = digest.first else {
        #expect(Bool(false), "Digest should be a text digest")
        return
    }
    
    let expectedContent = try String(contentsOf: txtFile, encoding: .utf8)
    #expect(content == expectedContent, "Content from the digest should match the file's entire content")
}
