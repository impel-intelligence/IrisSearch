//
//  UpdatingTests.swift
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

class IrisDB_UpdatingTests {
    @Test func updatingDocumentChangesContentAndPreservesID() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let chunker = BasicTextChunker()
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        let original = try await database.createDocument(uuid: uuid, title: "Original", description: "Original content", embeddableContent: [.text(content: "Original content")])

        let newContent = "Completely different content"
        let newTitle = "Updated title"
        let newDescription = "Updated description"
        try await database.updateDocument(uuid: uuid, title: newTitle, description: newDescription, embeddableContent: [.text(content: newContent)], chunker: chunker)
        
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let documents = try await dbQueue.read { db in
            return try IrisDocument.fetchAll(db)
        }
        
        #expect(documents.count == 1, "Updating should modify the existing document, not insert a new one.")
        
        let updated = documents.first!
        #expect(updated.uuid == uuid, "The uuid should be unchanged after an update.")
        #expect(updated.id == original.id, "The rowID should be preserved across an update.")
        #expect(updated.title == newTitle, "The title should reflect the updated value.")
        #expect(updated.description == newDescription, "The description should reflect the updated value.")
        
        let pieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)   
        }
        #expect(pieces.count == 1, "The updated single-chunk content should produce exactly one piece.")
        #expect(pieces.first?.text == newContent, "The stored piece should reflect the updated content.")
    }
    
    @Test func updatingDocumentReembedsContent() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let chunker = BasicTextChunker()
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        try await database.createDocument(uuid: uuid, title: "Original", description: "Original content", embeddableContent: [.text(content: "Original content")])

        // Use content large enough to produce more than one chunk.
        let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        let expectedChunks = chunker.chunk(content: newContent)
        #expect(expectedChunks.count > 1, "Test precondition: updated content should chunk into multiple pieces.")

        try await database.updateDocument(uuid: uuid, title: "Updated", description: "Updated content", embeddableContent: [.text(content: newContent)], chunker: chunker)
        
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)
        }
        #expect(pieces.count == expectedChunks.count, "The stored pieces should be regenerated for the new content.")
    }
    
    @Test func updatingNonexistentDocumentThrows() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let chunker = BasicTextChunker()
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        await #expect(throws: IrisDBError.documentNotFound) {
            try await database.updateDocument(uuid: UUID(), title: "Missing", description: "No such document", embeddableContent: [.text(content: "No such document")], chunker: chunker)
        }
    }
}
