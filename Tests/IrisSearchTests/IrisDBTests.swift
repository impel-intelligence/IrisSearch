//
//  IrisDBTests.swift
//  IrisSearch
//
// d by Taylor Lineman on 6/8/26.
//

import Testing
@testable import IrisSearch
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB

class TestingDirectories {
    let databaseName: String = "main"
    let baseURL: URL
    let bundleURL: URL
    let sqliteURL: URL
    let indexURL: URL
    
    init() {
        baseURL = FileManager.default.temporaryDirectory.appending(path: "tmp-database-\(UUID())")
        bundleURL = baseURL.appendingPathComponent("\(databaseName).irisdb")
        sqliteURL = bundleURL.appending(path: "map.sqlite")
        indexURL = bundleURL.appending(path: "indices")
    }
    
    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

@Test func creationIsIdempotent() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    
    // Initialize the database and tables.
    _ = try IrisDB(databaseLocation: directories.baseURL, databaseName: "main", embeddingProvider: embedder)

    // a second database, this should succeed even though we have already initialized another database instance.
    _ = try IrisDB(databaseLocation: directories.baseURL, databaseName: "main", embeddingProvider: embedder)
}

@Test func insertDocument() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    try await database.createDocument(uuid: uuid, content: content, chunker: chunker)
    
    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let documents = try await dbQueue.read { db in
        return try IrisDocument.fetchAll(db)
    }
    
    #expect(documents.count == 1, "Exactly one document should exist in the database.")
    
    let mainDocument = documents.first!
    
    #expect(mainDocument.uuid == uuid, "The document's id should match the provided ID.")
    #expect(mainDocument.content == content, "The document's content should match the provided ID.")
}

@Test func faissIndicesArd() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    
    _ = try await database.createDocument(uuid: uuid, content: content, chunker: chunker)
    let localIndexPath = IrisDB.IndexLocation.document(uuid: uuid).filePath(in: directories.indexURL)
    let globalIndexPath = IrisDB.IndexLocation.global.filePath(in: directories.indexURL)

    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index file should exist.")
    #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true, "The global index file should exist.")
}

@Test func faissIndicesAreValid() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    
    _ = try await database.createDocument(uuid: uuid, content: content, chunker: chunker)
    let localIndexPath = IrisDB.IndexLocation.document(uuid: uuid).filePath(in: directories.indexURL)
    let globalIndexPath = IrisDB.IndexLocation.global.filePath(in: directories.indexURL)
    
    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true)
    
    // Local index is a flat index, so make sure it loads
    _ = try FlatIndex.from(localIndexPath.path())
    
    #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true)

    // The global index is an IDMap
    let globalIndex = try IDMap.from(globalIndexPath.path())
    #expect(globalIndex.idMap().count == 1)
}


@Test func insertDocumentVectorsMatchProviderDimensions() async throws {
    let directories = TestingDirectories()
    
    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    try await database.createDocument(uuid: uuid, content: content, chunker: chunker)
    
    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let document = try await dbQueue.read { db in
        return try IrisDocument.fetchOne(db)
    }
    
    #expect(document != nil, "Document should exist.")
    guard let embeddings = document?.embeddings else { return }
    for embedding in embeddings {
        #expect(embedding.count == embedder.dimension, "Vector dimensions should match the embedding provider.")
    }
}


@Test func documentIsProperlyDelete() async throws {
    let directories = TestingDirectories()
        
    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    let document = try await database.createDocument(uuid: uuid, content: content, chunker: chunker)
    
    try await database.deleteDocument(uuid: document.uuid)
    
    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let recheckedDoc = try await dbQueue.read { db in
        return try IrisDocument.fetchOne(db)
    }

    #expect(recheckedDoc == nil, "Document should have been deleted from the database.")
    
    let localIndexPath = IrisDB.IndexLocation.document(uuid: document.uuid).filePath(in: directories.indexURL)
    
    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == false, "The document's faiss index should have been removed.")
}

@Test func readingDocument() async throws {
    let directories = TestingDirectories()
    
    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    try await database.createDocument(uuid: uuid, content: content, chunker: chunker)

    let readDocument = try await database.readDocument(uuid: uuid)
    #expect(readDocument != nil)
    #expect(readDocument?.uuid == uuid)
    #expect(readDocument?.content == content)
}


// MARK: Updating Documents

@Test func updatingDocumentChangesContentAndPreservesID() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let uuid = UUID()
    let original = try await database.createDocument(uuid: uuid, content: "Original content", chunker: chunker)

    let newContent = "Completely different content"
    try await database.updateDocument(uuid: uuid, content: newContent, chunker: chunker)

    let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
    let documents = try await dbQueue.read { db in
        return try IrisDocument.fetchAll(db)
    }

    #expect(documents.count == 1, "Updating should modify the existing document, not insert a new one.")

    let updated = documents.first!
    #expect(updated.uuid == uuid, "The uuid should be unchanged after an update.")
    #expect(updated.content == newContent, "The content should reflect the updated value.")
    #expect(updated.id == original.id, "The rowID should be preserved across an update.")
}

@Test func updatingDocumentReembedsContent() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let uuid = UUID()
    try await database.createDocument(uuid: uuid, content: "Original content", chunker: chunker)

    // Use content large enough to produce more than one chunk.
    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    #expect(expectedChunks.count > 1, "Test precondition: updated content should chunk into multiple pieces.")

    try await database.updateDocument(uuid: uuid, content: newContent, chunker: chunker)

    let updated = try await database.readDocument(uuid: uuid)
    #expect(updated?.embeddings.count == expectedChunks.count, "The stored embeddings should be regenerated for the new content.")
}

@Test func updatingNonexistentDocumentThrows() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    await #expect(throws: IrisDBError.documentNotFound) {
        try await database.updateDocument(uuid: UUID(), content: "No such document", chunker: chunker)
    }
}

@Test func updatingDocumentRefreshesLocalIndex() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let uuid = UUID()
    try await database.createDocument(uuid: uuid, content: "Original content", chunker: chunker)

    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    try await database.updateDocument(uuid: uuid, content: newContent, chunker: chunker)

    let localIndexPath = IrisDB.IndexLocation.document(uuid: uuid).filePath(in: directories.indexURL)
    #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index should still exist after an update.")

    let localIndex = try FlatIndex.from(localIndexPath.path())
    #expect(localIndex.count == expectedChunks.count, "The local index should hold one vector per chunk of the new content.")
}

@Test func updatingDocumentRebuildsGlobalIndexEntry() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let uuid = UUID()
    let document = try await database.createDocument(uuid: uuid, content: "Original content", chunker: chunker)

    let newContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
    let expectedChunks = chunker.chunk(content: newContent)
    try await database.updateDocument(uuid: uuid, content: newContent, chunker: chunker)

    let globalIndexPath = IrisDB.IndexLocation.global.filePath(in: directories.indexURL)
    let globalIndex = try IDMap.from(globalIndexPath.path())
    let ids = globalIndex.idMap()
    let documentID = try #require(document.id)

    #expect(ids.count == expectedChunks.count, "The global index should contain exactly one entry per chunk of the updated content, with no stale entries.")
    #expect(ids.allSatisfy { $0 == Int(documentID) }, "Every global index entry should be tagged with the document's rowID.")
}

// MARK: Global Index Add / Remove

@Test func addingDocumentsAccumulatesInGlobalIndex() async throws {
    let directories = TestingDirectories()

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let firstUUID = UUID()
    let secondUUID = UUID()
    let first = try await database.createDocument(uuid: firstUUID, content: "First document", chunker: chunker)
    let second = try await database.createDocument(uuid: secondUUID, content: "Second document", chunker: chunker)

    let expectedFirst = chunker.chunk(content: "First document").count
    let expectedSecond = chunker.chunk(content: "Second document").count

    let globalIndexPath = IrisDB.IndexLocation.global.filePath(in: directories.indexURL)
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
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, embeddingProvider: embedder)

    let keepUUID = UUID()
    let removeUUID = UUID()
    let keep = try await database.createDocument(uuid: keepUUID, content: "Document to keep", chunker: chunker)
    let remove = try await database.createDocument(uuid: removeUUID, content: "Document to remove", chunker: chunker)

    try await database.deleteDocument(uuid: removeUUID)

    let expectedKeep = chunker.chunk(content: "Document to keep").count

    let globalIndexPath = IrisDB.IndexLocation.global.filePath(in: directories.indexURL)
    let globalIndex = try IDMap.from(globalIndexPath.path())
    let ids = globalIndex.idMap()
    let keepID = try #require(keep.id)
    let removeID = try #require(remove.id)

    #expect(ids.filter { $0 == Int(removeID) }.isEmpty, "The deleted document's entries should be gone from the global index.")
    #expect(ids.filter { $0 == Int(keepID) }.count == expectedKeep, "The remaining document's entries should be untouched.")
    #expect(ids.count == expectedKeep, "Only the remaining document's entries should be left in the global index.")
}


//@Test func testIndexSearching() async throws {
//    let coreIndex = try FlatIndex(d: 512, metricType: .l2)
//    let index = try IDMap(subIndex: coreIndex)
//
//    let embedder = try NLEmbedder(language: .english)
//    let chunks: [String] = [
//        "Hello world",
//        "Hello world 2",
//        "Red Fish, Blue Fish"
//    ]
//
//    var embeddings: [[Float]] = []
//    embeddings.reserveCapacity(chunks.count)
//
//    for chunk in chunks {
//        // Embed the content chunk, and convert from a double to a float to match FAISS
//        var chunkEmbedding: [Float] = try await embedder.embed(content: chunk).map({Float($0)})
//
//        // Normalize the vector into a format suited for the L2 search metric.
//        faiss_fvec_renorm_L2(embedder.dimension, 1, &chunkEmbedding)
//
//        embeddings.append(chunkEmbedding)
//    }
//
//    if !index.isTrained {
//        print("Training index")
//        try index.train(embeddings)
//    }
//
//    try index.add(embeddings, ids: [0, 0, 5])
//
//    let query = try await embedder.embed(content: "Hello").map({Float($0)})
//    let result = try index.search([query], k: 2)
//    print(result.labels)
//}
