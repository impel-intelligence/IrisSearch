//
//  SearchIntegrationTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

import Testing
import Foundation
@testable import IrisSearch
@testable import Digester
import IrisCommon
import TestUtilities

class SearchIntegrationTests {
    @Test()
    func arxivProcessAndSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)
        
        let papersURL = Bundle.module.url(forResource: "Arxiv", withExtension: nil, subdirectory: "Test Documents")!
        let papers = try FileManager.default.contentsOfDirectory(atPath: papersURL.path(percentEncoded: false)).shuffled().prefix(10)
        
        let digestor = PDFDigester()

        for (index, paperName) in papers.enumerated() {
            let measurement = try await ContinuousClock().measure {
                let url = papersURL.appendingPathComponent(paperName, conformingTo: .pdf)
                let digest = try await digestor.digest(file: url, contextSize: embedder.dimension)
                try await database.createDocument(uuid: UUID(), title: paperName, description: paperName, embeddableContent: digest)
            }
            print("[\(index) - \(paperName)] \(measurement)")// Added \(digest.count) pieces")
        }
        
        let query = IrisQuery(text: "Binary Search")

        try await measurePerformance {
            _ = try await database.search(query: query, nItems: 10)
        }
    }
    
}
