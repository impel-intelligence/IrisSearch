//
//  IrisDB.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/8/26.
//

import Foundation
import GRDB
import SwiftFaiss
import SwiftFaissC

/// Database Structure File package
/// - Vector Indices
///     - all
///     - doc-1
///     - doct-2
/// - Map File
/// - Compressed long-term text storage

final class IrisDocument: Codable, Sendable, FetchableRecord, PersistableRecord {
    let id: UUID
    let content: String
    let embeddings: [[Float]]
    
    init(id: UUID, content: String, embeddings: [[Float]]) {
        self.id = id
        self.content = content
        self.embeddings = embeddings
    }
}

final class IrisDB {
    private var embeddingProvider: EmbeddingProvider
    
    private var databaseURL: URL
    private var sqliteURL: URL {
        return databaseURL.appending(path: "map.sqlite")
    }
    private var indexDirectory: URL {
        return databaseURL.appending(path: "indices")
    }
    
    init(databaseLocation: URL, databaseName: String = "main", embeddingProvider: EmbeddingProvider) throws {
        databaseURL = databaseLocation.appending(path: "\(databaseName).idb")
        self.embeddingProvider = embeddingProvider
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path()) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
        
        try initializeDB()
    }
    
    private func initializeDB() throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        try dbQueue.write { db in
            try db.create(table: "documents") { table in
                table.primaryKey("id", .text)
                table.column("content", .text).notNull()
                table.column("embeddings", .blob).notNull()
            }
            
            try db.create(virtualTable: "documents_ft", using: FTS5()) { table in
                table.synchronize(withTable: "documents")
                table.column("id")
                table.column("content")
            }
        }
    }
    
    func insertDocument(id: UUID, content: String, chunker: ContentChunker) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        let contentChunks = chunker.chunk(content: content)
        
        // Create an array to store the embeddings for each content chunk. Storing chunk embeddings results in more accurate semantic search in longer documents.
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(contentChunks.count)
        
        for chunk in contentChunks {
            // Embed the content chunk, and convert from a double to a float to match FAISS
            var chunkEmbedding: [Float] = try await embeddingProvider.embed(content: chunk).map({Float($0)})
            
            // Normalize the vector into a format suited for the L2 search metric.
            faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &chunkEmbedding)
            
            embeddings.append(chunkEmbedding)
        }
        
        // Create a document object
        let document = IrisDocument(id: id, content: content, embeddings: embeddings)
        
        // Insert into the document into the database
        try await dbQueue.write { db in
            try document.insert(db)
        }
        
        try await refreshIndex(for: document)
    }
    
    private func refreshIndex(for document: IrisDocument) async throws {
        let indexURL = indexDirectory.appending(component: document.id.uuidString)
        
        var index: FlatIndex
        if FileManager.default.fileExists(atPath: indexURL.path()),
           let flatIndex = try? FlatIndex.from(indexURL.path(percentEncoded: false)) {
            index = flatIndex
        }
        
        index = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
        
//        try index.train(document.v)
        try index.add(<#T##xs: [[Float]]##[[Float]]#>)

    }
    
//    private func refreshGlobalIndex {
//        
//    }
}

