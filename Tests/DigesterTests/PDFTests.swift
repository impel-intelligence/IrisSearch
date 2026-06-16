//
//  DigesterTests.swift
//  DigesterTests
//
//  by Taylor Lineman on 6/10/26.
//

import Testing
@testable import Digester
import Foundation

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
    let digest = try await digestor.digest(file: pdfFile.url)
        
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
//    guard case let .text(pdfContent) = digest.first else {
//        #expect(Bool(false), "The first content should be text")
//        return
//    }
//
//    #expect(pdfContent.trimmingCharacters(in: .newlines) == pdfFile.bodyText.trimmingCharacters(in: .newlines), "The body text should match the tested text.")
}
