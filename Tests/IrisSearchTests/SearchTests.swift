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

class IrisDB_SearchTests {
    @Test func basicSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let chunker = BasicTextChunker()
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Original content"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Different"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Holy smokes"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Sharks!"))
        
        try await database.search(query: .init(text: "original"), kItems: 2)
    }

}
