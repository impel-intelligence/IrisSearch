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

        try await database.createDocument(uuid: UUID(), embeddableContent: [.text(content: "Original content")])
        try await database.createDocument(uuid: UUID(), embeddableContent: [.text(content: "Different")])
        try await database.createDocument(uuid: UUID(), embeddableContent: [.text(content: "Holy smokes")])
        try await database.createDocument(uuid: UUID(), embeddableContent: [.text(content: "Sharks!")])
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "original"), kItems: 2)
        }
    }
    
    @Test()
    func sonnetSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let sonnetURL = Bundle.module.url(forResource: "Sonnets", withExtension: nil, subdirectory: "Test Documents")!
        let sonnets = try FileManager.default.contentsOfDirectory(atPath: sonnetURL.path(percentEncoded: false))
        
        for sonnet in sonnets {
            let url = sonnetURL.appendingPathComponent(sonnet, conformingTo: .plainText)
            let content = try String(contentsOf: url, encoding: .utf8)
            try await database.createDocument(uuid: UUID(), embeddableContent: [.text(content: content)])
        }
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "Music and sadness"), kItems: 2)
        }
    }
}
