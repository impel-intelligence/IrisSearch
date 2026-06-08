//
//  IrisDBTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/8/26.
//

import Testing
@testable import IrisSearch
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB

@Test func creationIsIdempotent() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")

    let embedder = try NLEmbedder(language: .english)
    
    // Initialize the database and create tables.
    _ = try IrisDB(databaseLocation: tmp, databaseName: "main", embeddingProvider: embedder)

    // Create a second database, this should succeed even though we have already initialized another database instance.
    _ = try IrisDB(databaseLocation: tmp, databaseName: "main", embeddingProvider: embedder)
    
    try FileManager.default.removeItem(at: tmp)
}

@Test func insertDocument() async throws {
    let databaseName = "main"
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")
    let bundleURL = tmp.appendingPathComponent("\(databaseName).irisdb")
    let sqliteURL = bundleURL.appending(path: "map.sqlite")
    
    defer {
        try? FileManager.default.removeItem(at: tmp)
    }

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: tmp, databaseName: databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    try await database.insertDocument(id: uuid, content: content, chunker: chunker)
    
    let dbQueue = try DatabaseQueue(path: sqliteURL.path())
    let documents = try await dbQueue.read { db in
        return try IrisDocument.fetchAll(db)
    }
    
    #expect(documents.count == 1, "Exactly one document should exist in the database.")
    
    let mainDocument = documents.first!
    
    #expect(mainDocument.uuid == uuid, "The document's id should match the provided ID.")
    #expect(mainDocument.content == content, "The document's content should match the provided ID.")
}

@Test func testLocalIndexCreated() async throws {
    let databaseName = "main"
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")
    let bundleURL = tmp.appendingPathComponent("\(databaseName).irisdb")
    let indexURL = bundleURL.appending(path: "indices")

    defer {
        try? FileManager.default.removeItem(at: tmp)
    }

    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: tmp, databaseName: databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    
    let document = try await database.insertDocument(id: uuid, content: content, chunker: chunker)
    let indexPath = indexURL.appending(path: "\(document.uuid.uuidString).index")
    
    #expect(FileManager.default.fileExists(atPath: indexPath.path()) == true, "The index file should exist at \(indexPath.path()).")
}


@Test func insertDocumentVectorsMatchProviderDimensions() async throws {
    let databaseName = "main"
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")
    let bundleURL = tmp.appendingPathComponent("\(databaseName).irisdb")
    let sqliteURL = bundleURL.appending(path: "map.sqlite")
    
    defer {
        try? FileManager.default.removeItem(at: tmp)
    }
    
    let embedder = try NLEmbedder(language: .english)
    let chunker = BasicChunker()
    let database = try IrisDB(databaseLocation: tmp, databaseName: databaseName, embeddingProvider: embedder)
    
    let uuid = UUID()
    let content = "Test content"
    try await database.insertDocument(id: uuid, content: content, chunker: chunker)
    
    let dbQueue = try DatabaseQueue(path: sqliteURL.path())
    let document = try await dbQueue.read { db in
        return try IrisDocument.fetchOne(db)
    }
    
    #expect(document != nil, "Document should exist.")
    guard let embeddings = document?.embeddings else { return }
    for embedding in embeddings {
        #expect(embedding.count == embedder.dimension, "Vector dimensions should match the embedding provider.")
    }
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
