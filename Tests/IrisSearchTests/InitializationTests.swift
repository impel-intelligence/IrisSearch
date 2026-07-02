//
//  InitializationTests.swift
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

// MARK: Initialization
class IrisDB_InitializationTests {
    @Test func creationIsIdempotent() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        
        // Initialize the database and tables.
        _ = try IrisDB(databaseLocation: directories.baseURL, databaseName: "main", textEmbedder: embedder, textChunker: BasicTextChunker())
        
        // a second database, this should succeed even though we have already initialized another database instance.
        _ = try IrisDB(databaseLocation: directories.baseURL, databaseName: "main", textEmbedder: embedder, textChunker: BasicTextChunker())
    }
    
    // MARK: Creating Documents
    
    @Test func insertDocument() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        let content = "Test content"
        let title = "Test title"
        let description = "Test description"
        let document = try await database.createDocument(uuid: uuid, title: title, description: description, embeddableContent: [.text(content: content)])

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let documents = try await dbQueue.read { db in
            return try IrisDocument.fetchAll(db)
        }

        #expect(documents.count == 1, "Exactly one document should exist in the database.")
        #expect(documents.first?.uuid == uuid, "The document's uuid should match the provided uuid.")
        #expect(documents.first?.title == title, "The document's title should match the provided title.")
        #expect(documents.first?.description == description, "The document's description should match the provided description.")
        
        // The chunked content should be persisted as document pieces tied to the parent.
        let pieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)
        }
        
        #expect(pieces.count == 1, "A single short text document should produce exactly one piece.")
        #expect(pieces.first?.parentID == document.id, "Each piece should reference its parent document's rowID.")
        #expect(pieces.first?.text == content, "The stored piece should carry the original text content.")
    }
    
    @Test func insertDocumentVectorsMatchProviderDimensions() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        try await database.createDocument(uuid: uuid, title: "Test title", description: "Test description", embeddableContent: [.text(content: "Test Content")])
        
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)
        }
        
        #expect(!pieces.isEmpty, "The document's pieces should be persisted.")
        for piece in pieces {
            #expect(piece.embeddings.count == embedder.dimension, "Each piece's vector should match the embedding provider dimension.")
        }
    }
    
    @Test func readingDocument() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        let content = "Test content"
        let title = "Test title"
        let description = "Test description"
        try await database.createDocument(uuid: uuid, title: title, description: description, embeddableContent: [.text(content: content)])

        let readDocument = try await database.readDocument(uuid: uuid)
        #expect(readDocument != nil)
        #expect(readDocument?.uuid == uuid)
        #expect(readDocument?.title == title, "Reading a document should round-trip its title.")
        #expect(readDocument?.description == description, "Reading a document should round-trip its description.")
        #expect(readDocument?.pieces.count == 1, "Reading a document should load its persisted pieces.")
        #expect(readDocument?.pieces.first?.text == content, "The loaded piece should round-trip the original content.")
    }
    
    @Test func readDocumentByTitle() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        let content = "Test content"
        let title = "Test title"
        let description = "Test description"
        try await database.createDocument(uuid: uuid, title: title, description: description, embeddableContent: [.text(content: content)])
        
        let readDocument = try await database.readDocument(title: title)
        #expect(readDocument != nil)
        #expect(readDocument?.uuid == uuid)
        #expect(readDocument?.title == title, "Reading a document should round-trip its title.")
        #expect(readDocument?.description == description, "Reading a document should round-trip its description.")
        #expect(readDocument?.pieces.count == 1, "Reading a document should load its persisted pieces.")
        #expect(readDocument?.pieces.first?.text == content, "The loaded piece should round-trip the original content.")
    }

    
}
