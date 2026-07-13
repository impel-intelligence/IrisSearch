//
//  DigesterTests.swift
//  DigesterTests
//
//  by Taylor Lineman on 6/10/26.
//

import Testing
@testable import Digester
import Foundation
import TestUtilities

struct PDFArgument {
    var url: URL
    var numberOfPages: Int
    var numberOfPagesWithText: Int
}

@Test("Ensure pdf digester can process PDFs", arguments: [
    PDFArgument(
        url: Bundle.module.url(forResource: "simple-pdf-feature-test", withExtension: "pdf", subdirectory: "Test Documents/pdf")!,
        numberOfPages: 3, numberOfPagesWithText: 2),
    PDFArgument(
        url: Bundle.module.url(forResource: "pdf-ingestion-test-suite", withExtension: "pdf", subdirectory: "Test Documents/pdf")!,
        numberOfPages: 10, numberOfPagesWithText: 9)
]) func testPDFDigester(pdfFile: PDFArgument) async throws {
    let digestor = PDFDigester()
    let digest = try await digestor.digest(file: pdfFile.url, contextSize: 100000)
        
    let nImage = digest.count { content in
        switch content {
        case .image:
            return true
        default:
            return false
        }
    }

    let nText = digest.count { content in
        switch content {
        case .text:
            return true
        default:
            return false
        }
    }

    
    #expect(nImage == pdfFile.numberOfPages, "The number of images should match the number of PDF pages.")
    #expect(nText == pdfFile.numberOfPagesWithText, "The number of text elements should match the number of PDF pages with text.")
}

@Test("Speed Test", arguments: [
    Bundle.module.url(forResource: "long-pdf-test", withExtension: "pdf", subdirectory: "Test Documents/pdf")!
]) func testPDFConversioNSpeed(pdfURL: URL) async throws {
    let digestor = PDFDigester()
    
    let performance = try await measurePerformance(nRuns: 10) {
        _ = try await digestor.digest(file: pdfURL, contextSize: 100000)
    }
    
    #expect(performance.average < 1)
}
