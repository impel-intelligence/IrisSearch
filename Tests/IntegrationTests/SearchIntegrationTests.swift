//
//  SearchIntegrationTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//  Edited by Claude Opus 5 (Anthropic) on 2026-08-17
//

import Testing
import Foundation
@testable import IrisSearch
@testable import Digester
import IrisCommon
import TestUtilities
import AppleIntelligenceEmbedder

/// A directory of PDFs to digest and search, or `nil` when no corpus has been supplied.
///
/// The arXiv papers this suite was originally written against are not distributed with the repository, because arXiv's default license does not grant redistribution rights to third parties. Drop any collection of PDFs into `Tests/Test Documents/Arxiv` to run these tests locally; see the README in that directory.
///
/// - Authored by: Claude Opus 5 (Anthropic)
private let pdfCorpusURL: URL? = Bundle.module.url(forResource: "Arxiv", withExtension: nil, subdirectory: "Test Documents")

@Suite(
    "Search integration testing",
    .tags(.lfs),
    .enabled(if: pdfCorpusURL != nil, "No PDF corpus supplied; see Tests/Test Documents/README.md")
)
struct SearchIntegrationTests {
    @Test("Test performance of search against a collection of PDF documents")
    func arxivProcessAndSearch() async throws {
        let papersURL = try #require(pdfCorpusURL)

        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let papers = try FileManager.default.contentsOfDirectory(atPath: papersURL.path(percentEncoded: false))
            .filter { $0.lowercased().hasSuffix(".pdf") }
            .shuffled()
            .prefix(10)

        try #require(!papers.isEmpty, "Corpus directory exists but contains no PDFs")

        let digestor = PDFDigester()

        for (index, paperName) in papers.enumerated() {
            let measurement = try await ContinuousClock().measure {
                let url = papersURL.appendingPathComponent(paperName, conformingTo: .pdf)
                let digest = try await digestor.digest(file: url, contextSize: embedder.dimension)
                try await database.createDocument(uuid: UUID(), title: paperName, description: paperName, embeddableContent: digest)
            }
            print("[\(index) - \(paperName)] \(measurement)")
        }

        let query = IrisQuery(text: "Binary Search")

        try await measurePerformance {
            _ = try await database.search(query: query, nItems: 10)
        }
    }
}
