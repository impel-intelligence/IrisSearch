//
//  IrisDBTests.swift
//  IrisSearch
//
//  by Taylor Lineman on 6/8/26.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB

class TestingDirectories {
    let databaseName: String = "main"
    let baseURL: URL
    let bundleURL: URL
    let sqliteURL: URL
    let textIndexURL: URL
//    let imageIndexURL: URL

    init() {
        baseURL = FileManager.default.temporaryDirectory.appending(path: "tmp-database-\(UUID())")
        bundleURL = baseURL.appendingPathComponent("\(databaseName).irisdb")
        sqliteURL = bundleURL.appending(path: "map.sqlite")
        textIndexURL = bundleURL.appending(path: "text-index")
//        imageIndexURL = bundleURL.appending(path: "image-index")
    }

    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

// MARK: Test Helpers

/// Wrap a plain string as the digester would hand it to intake: a single text content unit.
private func textContent(_ string: String) -> [EmbeddableContent] {
    return [.text(content: string)]
}

private extension DocumentPiece {
    /// Convenience for reading the text payload of a piece in assertions.
    var text: String? {
        if case .text(let content) = content { return content }
        return nil
    }
}

// MARK: Initialization

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
    let document = try await database.createDocument(uuid: uuid, embeddableContent: textContent(content))

    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let documents = try await dbQueue.read { db in
        return try IrisDocument.fetchAll(db)
    }

    #expect(documents.count == 1, "Exactly one document should exist in the database.")
    #expect(documents.first?.uuid == uuid, "The document's uuid should match the provided uuid.")

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
    try await database.createDocument(uuid: uuid, embeddableContent: textContent("Test content"))

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
    try await database.createDocument(uuid: uuid, embeddableContent: textContent(content))

    let readDocument = try await database.readDocument(uuid: uuid)
    #expect(readDocument != nil)
    #expect(readDocument?.uuid == uuid)
    #expect(readDocument?.pieces.count == 1, "Reading a document should load its persisted pieces.")
    #expect(readDocument?.pieces.first?.text == content, "The loaded piece should round-trip the original content.")
}

// MARK: Deleting Documents

@Test func documentIsProperlyDelete() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    let content = "Test content"
    let document = try await database.createDocument(uuid: uuid, embeddableContent: textContent(content))

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

// MARK: Updating Documents

@Test func updatingDocumentChangesContentAndPreservesID() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicTextChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    let original = try await database.createDocument(uuid: uuid, embeddableContent: textContent("Original content"))

    let newContent = "Completely different content"
    try await database.updateDocument(uuid: uuid, embeddableContent: textContent(newContent), chunker: chunker)

    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let documents = try await dbQueue.read { db in
        return try IrisDocument.fetchAll(db)
    }

    #expect(documents.count == 1, "Updating should modify the existing document, not insert a new one.")

    let updated = documents.first!
    #expect(updated.uuid == uuid, "The uuid should be unchanged after an update.")
    #expect(updated.id == original.id, "The rowID should be preserved across an update.")

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
    try await database.createDocument(uuid: uuid, embeddableContent: textContent("Original content"))

    // Use content large enough to produce more than one chunk.
    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    #expect(expectedChunks.count > 1, "Test precondition: updated content should chunk into multiple pieces.")

    try await database.updateDocument(uuid: uuid, embeddableContent: textContent(newContent), chunker: chunker)

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
        try await database.updateDocument(uuid: UUID(), embeddableContent: textContent("No such document"), chunker: chunker)
    }
}

// MARK: FAISS Index

@Test func faissIndicesAreCreated() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    let content = "Test content"

    _ = try await database.createDocument(uuid: uuid, embeddableContent: textContent(content))
    let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
    let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)

    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index file should exist.")
    #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true, "The global index file should exist.")
}

@Test func faissIndicesAreValid() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    let content = "Test content"

    _ = try await database.createDocument(uuid: uuid, embeddableContent: textContent(content))
    let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
    let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)

    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true)

    // Local index is a flat index, so make sure it loads and holds one vector per chunk.
    let localIndex = try FlatIndex.from(localIndexPath.path())
    #expect(localIndex.count == 1, "The local index should hold one vector for the single-chunk document.")

    #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true)

    // The global index is an IDMap
    let globalIndex = try IDMap.from(globalIndexPath.path())
    #expect(globalIndex.idMap().count == 1, "The global index should hold one vector for the single-chunk document.")
}

@Test func updatingDocumentRefreshesLocalIndex() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicTextChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    try await database.createDocument(uuid: uuid, embeddableContent: textContent("Original content"))

    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    try await database.updateDocument(uuid: uuid, embeddableContent: textContent(newContent), chunker: chunker)

    let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index should still exist after an update.")

    let localIndex = try FlatIndex.from(localIndexPath.path())
    #expect(localIndex.count == expectedChunks.count, "The local index should hold one vector per chunk of the new content.")
}

@Test func updatingDocumentRebuildsGlobalIndexEntry() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicTextChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let uuid = UUID()
    let document = try await database.createDocument(uuid: uuid, embeddableContent: textContent("Original content"))

    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    try await database.updateDocument(uuid: uuid, embeddableContent: textContent(newContent), chunker: chunker)

    let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
    let globalIndex = try IDMap.from(globalIndexPath.path())
    let ids = globalIndex.idMap()
    let documentID = try #require(document.id)

    #expect(ids.count == expectedChunks.count, "The global index should contain exactly one entry per chunk of the updated content, with no stale entries.")
    #expect(ids.allSatisfy { $0 == Int(documentID) }, "Every global index entry should be tagged with the document's rowID.")
}

@Test func addingDocumentsAccumulatesInGlobalIndex() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicTextChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let firstUUID = UUID()
    let secondUUID = UUID()
    let first = try await database.createDocument(uuid: firstUUID, embeddableContent: textContent("First document"))
    let second = try await database.createDocument(uuid: secondUUID, embeddableContent: textContent("Second document"))

    let expectedFirst = chunker.chunk(content: "First document").count
    let expectedSecond = chunker.chunk(content: "Second document").count

    let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
    let globalIndex = try IDMap.from(globalIndexPath.path())
    let ids = globalIndex.idMap()
    let firstID = try #require(first.id)
    let secondID = try #require(second.id)

    #expect(firstID != secondID, "Each document should receive a distinct rowID.")
    #expect(ids.count == expectedFirst + expectedSecond, "The global index should contain entries for both documents.")
    #expect(ids.filter { $0 == Int(firstID) }.count == expectedFirst, "The first document's entries should be present in the global index.")
    #expect(ids.filter { $0 == Int(secondID) }.count == expectedSecond, "The second document's entries should be present in the global index.")
}

@Test func deletingDocumentRemovesItsEntriesFromGlobalIndex() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicTextChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())

    let keepUUID = UUID()
    let removeUUID = UUID()
    let keep = try await database.createDocument(uuid: keepUUID, embeddableContent: textContent("Document to keep"))
    let remove = try await database.createDocument(uuid: removeUUID, embeddableContent: textContent("Document to remove"))

    try await database.deleteDocument(uuid: removeUUID)

    let expectedKeep = chunker.chunk(content: "Document to keep").count

    let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
    let globalIndex = try IDMap.from(globalIndexPath.path())
    let ids = globalIndex.idMap()
    let keepID = try #require(keep.id)
    let removeID = try #require(remove.id)

    #expect(ids.filter { $0 == Int(removeID) }.isEmpty, "The deleted document's entries should be gone from the global index.")
    #expect(ids.filter { $0 == Int(keepID) }.count == expectedKeep, "The remaining document's entries should be untouched.")
    #expect(ids.count == expectedKeep, "Only the remaining document's entries should be left in the global index.")
}
