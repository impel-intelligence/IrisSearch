//
//  DeletionTests.swift
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

class IrisDB_DeletionTests {
    
    @Test func documentIsProperlyDelete() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let uuid = UUID()
        let content = "Test content"
        let location = DocumentLocation(sequenceIndex: 0, anchor: .text(characterRange: 0..<content.count))
        let document = try await database.createDocument(uuid: uuid, title: "Test title", description: "Test description", embeddableContent: [.text(content: content, location: location)])
        
        try await database.deleteDocument(uuid: document.uuid)
        
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let recheckedDoc = try await dbQueue.read { db in
            return try IrisDocument.fetchOne(db)
        }
        
        #expect(recheckedDoc == nil, "Document should have been deleted from the database.")
        
        // Deleting the parent should cascade and remove its pieces.
        let remainingPieces = try await dbQueue.read { db in
            return try DocumentPiece.fetchAll(db)
        }
        #expect(remainingPieces.isEmpty, "Deleting a document should cascade and remove its pieces.")
        
        let localIndexPath = FaissIndex.IndexLocation.document(uuid: document.uuid).filePath(in: directories.textIndexURL)
        
        #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == false, "The document's faiss index should have been removed.")
    }
}
