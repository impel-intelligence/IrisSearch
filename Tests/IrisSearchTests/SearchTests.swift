//
//  SearchTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//  Edited by Claude Sonnet 4.6 (Anthropic) on 2026-07-13

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB
import TestUtilities
import AppleIntelligenceEmbedder

class IrisDB_SearchTests {
    @Test()
    func basicSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let originalContent = "Original content"
        let differentContent = "Different"
        let holySmokesContent = "Holy smokes"
        let sharksContent = "Sharks!"

        try await database.createDocument(uuid: UUID(), title: "Original", description: originalContent, embeddableContent: [.text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<originalContent.count)))])
        try await database.createDocument(uuid: UUID(), title: "Different", description: differentContent, embeddableContent: [.text(content: differentContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<differentContent.count)))])
        try await database.createDocument(uuid: UUID(), title: "Holy smokes", description: holySmokesContent, embeddableContent: [.text(content: holySmokesContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<holySmokesContent.count)))])
        try await database.createDocument(uuid: UUID(), title: "Sharks", description: sharksContent, embeddableContent: [.text(content: sharksContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<sharksContent.count)))])
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "original"), nItems: 2)
        }
    }
    
    @Test()
    func sonnetSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)
        
        let sonnetURL = Bundle.module.url(forResource: "Sonnets", withExtension: nil, subdirectory: "Test Documents")!
        let sonnetPaths = try FileManager.default.contentsOfDirectory(atPath: sonnetURL.path(percentEncoded: false))
        
        var sonnets: [UUID: String] = [:]
        
        let loadingTime = try await ContinuousClock().measure {
            for sonnet in sonnetPaths {
                let url = sonnetURL.appendingPathComponent(sonnet, conformingTo: .plainText)
                let content = try String(contentsOf: url, encoding: .utf8)
                let uuid = UUID()
                sonnets[uuid] = content
                try await database.createDocument(uuid: uuid, title: sonnet, description: sonnet, embeddableContent: [.text(content: content, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<content.count)))])
            }
        }
        print("Loaded Documents in \(loadingTime)")
        
        let kItems = 10
        let documents = try await database.search(query: .init(text: "glass"), nItems: kItems)
        #expect(documents.count == kItems)        
    }
    
    @Test()
    func basicSingleDocumentSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let id: UUID = UUID()
        let originalContent = "Original content"
        let differentContent = "Different"
        let holySmokesContent = "Holy smokes"
        let sharksContent = "Sharks!"
        
        let embeddableContent: [EmbeddableContent] = [
            .text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 4, anchor: .text(characterRange: 0..<originalContent.count))),
            .text(content: differentContent, location: DocumentLocation(sequenceIndex: 1, documentLength: 4, anchor: .text(characterRange: 0..<differentContent.count))),
            .text(content: holySmokesContent, location: DocumentLocation(sequenceIndex: 2, documentLength: 4, anchor: .text(characterRange: 0..<holySmokesContent.count))),
            .text(content: sharksContent, location: DocumentLocation(sequenceIndex: 3, documentLength: 4, anchor: .text(characterRange: 0..<sharksContent.count))),
        ]

        try await database.createDocument(uuid: id, title: "Original", description: originalContent, embeddableContent: embeddableContent)

        try await measurePerformance {
            let results = try await database.search(within: id, query: .init(text: "Original"), nItems: 5)
            let topResultContent = results.importantPieces.first?.content.textContent ?? ""
            #expect(topResultContent.contains("Original"))
        }
    }
}
