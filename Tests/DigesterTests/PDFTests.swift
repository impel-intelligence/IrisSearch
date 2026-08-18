//
//  DigesterTests.swift
//  DigesterTests
//
//  by Taylor Lineman on 6/10/26.
//  Edited by Claude Opus 5 (Anthropic) on 2026-08-17
//

import Testing
@testable import Digester
import IrisCommon
import Foundation
import TestUtilities

/// A directory of PDFs used by the bulk speed test, or `nil` when no corpus has been supplied.
///
/// The arXiv papers this was originally written against are not distributed with the repository, because arXiv's default license does not grant redistribution rights to third parties. Drop any collection of PDFs into `Tests/Test Documents/Arxiv` to run this locally; see the README in that directory.
///
/// - Authored by: Claude Opus 5 (Anthropic)
private let pdfCorpusURL: URL? = Bundle.module.url(forResource: "Arxiv", withExtension: nil, subdirectory: "Test Documents")

struct PDFArgument {
    var url: URL
    var numberOfPages: Int
    var numberOfPagesWithText: Int
}

struct PDFTests {
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
    
    // Authored by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // PDFDigester chunks each page separately, then patches every text piece's documentLength to the true
    // whole-document total once all pages are known (see the `withNewDocumentLength` call in `digest`). A small
    // contextSize here forces multiple chunks per page, so a page-only (unreconciled) documentLength would
    // visibly diverge from the true total this test checks for.
    @Test("Text pieces across all pages share one correct documentLength and a contiguous sequenceIndex", arguments: [
        Bundle.module.url(forResource: "simple-pdf-feature-test", withExtension: "pdf", subdirectory: "Test Documents/pdf")!,
        Bundle.module.url(forResource: "pdf-ingestion-test-suite", withExtension: "pdf", subdirectory: "Test Documents/pdf")!
    ]) func testPDFDigesterDocumentLengthReconciliation(pdfFile: URL) async throws {
        let digestor = PDFDigester()
        let digest = try await digestor.digest(file: pdfFile, contextSize: 200)
        
        let textLocations: [DocumentLocation] = digest.compactMap { piece in
            guard case .text = piece else { return nil }
            return piece.location
        }
        
        #expect(!textLocations.isEmpty)
        #expect(textLocations.count > 1, "Test precondition: a small contextSize should split the PDF into multiple text pieces across its pages")
        
        let expectedDocumentLength = textLocations.count
        for location in textLocations {
            #expect(location.documentLength == expectedDocumentLength, "Every text piece should report the true total text-piece count across the whole document, not just its own page's count")
        }
        
        // sequenceIndex should be contiguous and unique across the whole document, proving pages were reconciled
        // into one continuous sequence rather than each page restarting its own sequence at 0.
        let sequenceIndices = textLocations.map(\.sequenceIndex).sorted()
        #expect(sequenceIndices == Array(0..<expectedDocumentLength), "sequenceIndex values should be contiguous 0..<documentLength across all pages")
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
    
    @Test("Speed Small PDFS", .enabled(if: pdfCorpusURL != nil, "No PDF corpus supplied; see Tests/Test Documents/README.md"))
    func testPDFConversionSpeedSmallPDFS() async throws {
        let papersURL = try #require(pdfCorpusURL)
        let papers = try FileManager.default.contentsOfDirectory(atPath: papersURL.path(percentEncoded: false))
            .filter { $0.lowercased().hasSuffix(".pdf") }
            .shuffled()
        try #require(!papers.isEmpty, "Corpus directory exists but contains no PDFs")

        let digester = PDFDigester()
        
        let performance = try await measurePerformance(nRuns: 10, array: papers) { path in
            let url = papersURL.appendingPathComponent(path, conformingTo: .pdf)
            _ = try await digester.digest(file: url, contextSize: 100000)
        }
        
        #expect(performance.average < 1)
    }
}
