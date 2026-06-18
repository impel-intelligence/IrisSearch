//
//  SearchTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB
import TestUtilities

class IrisDB_SearchTests {
    @Test()
    func basicSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        nonisolated(unsafe) let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

        try await database.createDocument(uuid: UUID(), title: "Original", description: "Original content", embeddableContent: [.text(content: "Original content")])
        try await database.createDocument(uuid: UUID(), title: "Different", description: "Different", embeddableContent: [.text(content: "Different")])
        try await database.createDocument(uuid: UUID(), title: "Holy smokes", description: "Holy smokes", embeddableContent: [.text(content: "Holy smokes")])
        try await database.createDocument(uuid: UUID(), title: "Sharks", description: "Sharks!", embeddableContent: [.text(content: "Sharks!")])
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "original"), nItems: 2)
        }
    }
    
    @Test()
    func sonnetSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let sonnetURL = Bundle.module.url(forResource: "Sonnets", withExtension: nil, subdirectory: "Test Documents")!
        let sonnetPaths = try FileManager.default.contentsOfDirectory(atPath: sonnetURL.path(percentEncoded: false))
        
        var sonnets: [UUID: String] = [:]
        
        let loadingTime = try await ContinuousClock().measure {
            for sonnet in sonnetPaths {
                let url = sonnetURL.appendingPathComponent(sonnet, conformingTo: .plainText)
                let content = try String(contentsOf: url, encoding: .utf8)
                let uuid = UUID()
                sonnets[uuid] = content
                try await database.createDocument(uuid: uuid, title: sonnet, description: sonnet, embeddableContent: [.text(content: content)])
            }
        }
        print("Loaded Documents in \(loadingTime)")
        
        let kItems = 10
        let documents = try await database.search(query: .init(text: "sad music"), nItems: kItems)
        #expect(documents.count == kItems)        
    }
}
