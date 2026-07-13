//
//  UpdatingTests.swift
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

class IrisDB_UpdatingTests {
    @Test func updatingDocumentChangesContentAndPreservesID() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let originalContent = "Original content"
        let original = try await database.createDocument(uuid: uuid, title: "Original", description: originalContent, embeddableContent: [.text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<originalContent.count)))])

        let newContent = "Completely different content"
        let newTitle = "Updated title"
        let newDescription = "Updated description"
        try await database.updateDocument(uuid: uuid, title: newTitle, description: newDescription, embeddableContent: [.text(content: newContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<newContent.count)))])

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

    // Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // IrisDB no longer chunks content itself, so this test supplies multiple pre-chunked pieces directly,
    // the way a Digester now would, instead of relying on IrisDB to split one long string into many.
    @Test func updatingDocumentReembedsContent() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let originalContent = "Original content"
        try await database.createDocument(uuid: uuid, title: "Original", description: originalContent, embeddableContent: [.text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<originalContent.count)))])

        // Multiple pre-chunked pieces, standing in for what a Digester's chunker would now produce upstream.
        let newChunks = ["Lorem ipsum dolor sit amet.", "Consectetur adipiscing elit.", "Sed do eiusmod tempor incididunt."]

        try await database.updateDocument(uuid: uuid, title: "Updated", description: "Updated content", embeddableContent: chunkedEmbeddableContent(newChunks))

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)
        }
        #expect(pieces.count == newChunks.count, "The stored pieces should be regenerated to match the new supplied chunks.")
    }

    @Test func updatingNonexistentDocumentThrows() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let missingContent = "No such document"
        await #expect(throws: IrisDBError.documentNotFound) {
            try await database.updateDocument(uuid: UUID(), title: "Missing", description: missingContent, embeddableContent: [.text(content: missingContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<missingContent.count)))])
        }
    }
}
