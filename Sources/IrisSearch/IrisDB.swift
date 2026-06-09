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

final class IrisDocument: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName: String = "documents"
    
    nonisolated(unsafe) var id: Int64 = 0
    let uuid: UUID
    let content: String
    let embeddings: [[Float]]
    
    init(uuid: UUID, content: String, embeddings: [[Float]]) {
        self.uuid = uuid
        self.content = content
        self.embeddings = embeddings
    }
    
    func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

final class IrisDB {
    private static let databaseExtension = "irisdb"
    private static let indexExtension = "index"
    
    enum IndexLocation {
        case global
        case document(uuid: UUID)
        
        func filePath(in location: URL) -> URL {
            switch self {
            case .global:
                return location.appending(component: "global").appendingPathExtension(IrisDB.indexExtension)
            case .document(let uuid):
                return location.appending(component: uuid.uuidString).appendingPathExtension(IrisDB.indexExtension)
            }
        }
    }

    private var embeddingProvider: EmbeddingProvider
    
    private var databaseURL: URL
    private var sqliteURL: URL {
        return databaseURL.appending(path: "map").appendingPathExtension("sqlite")
    }
    private var indexDirectory: URL {
        return databaseURL.appending(path: "indices")
    }
    
    init(databaseLocation: URL, databaseName: String = "main", embeddingProvider: EmbeddingProvider) throws {
        databaseURL = databaseLocation.appending(path: databaseName).appendingPathExtension(IrisDB.databaseExtension)
        self.embeddingProvider = embeddingProvider
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path()) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
        
        if !FileManager.default.fileExists(atPath: indexDirectory.path()) {
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        }
        
        try initializeDB()
    }
    
    private func initializeDB() throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        try dbQueue.write { db in
            try db.create(table: "documents", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).notNull().unique()
                table.column("content", .text).notNull()
                table.column("embeddings", .jsonb).notNull()
            }
            
            try db.create(virtualTable: "documents_ft", ifNotExists: true, using: FTS5()) { table in
                table.synchronize(withTable: "documents")
                table.column("id")
                table.column("content")
            }
        }
    }
    
    @discardableResult
    public func insertDocument(uuid: UUID, content: String, chunker: ContentChunker) async throws -> IrisDocument {
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
        let document = IrisDocument(uuid: uuid, content: content, embeddings: embeddings)
        
        // Insert into the document into the database
        try await dbQueue.write { db in
            try document.insert(db)
        }
        
        try await refreshIndex(for: document)
        try await refreshGlobalIndex()
        
        return document
    }
    
    public func deleteDocument(uuid: UUID) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        _ = try await dbQueue.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": uuid])
        }
        
        let indexURL = IndexLocation.document(uuid: uuid).filePath(in: indexDirectory)
        try FileManager.default.removeItem(at: indexURL)
        
        try await refreshGlobalIndex()
    }
}

// MARK: Index Management
extension IrisDB {
    private func refreshGlobalIndex() async throws {
        let indexURL = IndexLocation.global.filePath(in: indexDirectory)
        
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        let documents = try await dbQueue.read { db in
            return try IrisDocument.fetchAll(db)
        }
        
        // Create parallel arrays of embeddings and their corresponding document indices
        var embeddings: [[Float]] = []
        var ids: [Int] = []
        
        for document in documents {
            // For each embedding in the document, add it with the document's rowID as its ID
            for embedding in document.embeddings {
                embeddings.append(embedding)
                ids.append(Int(document.id))
            }
        }
        
        var index: IDMap
        if FileManager.default.fileExists(atPath: indexURL.path()),
           let flatIndex = try? IDMap.from(indexURL.path(percentEncoded: false)) {
            index = flatIndex
        } else {
            let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
            index = try IDMap(subIndex: coreIndex)
        }
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(embeddings)
        }
        
        // Add the data to the index with their corresponding IDs
        try index.add(embeddings, ids: ids)
        // Save the global index
        try index.saveToFile(indexURL.path())
    }
    
    private func refreshIndex(for document: IrisDocument) async throws {
        let indexURL = IndexLocation.document(uuid: document.uuid).filePath(in: indexDirectory)
        
        // Use a flat index for single document indices as we do not need anything faster.
        var index: FlatIndex
        if FileManager.default.fileExists(atPath: indexURL.path()),
           let flatIndex = try? FlatIndex.from(indexURL.path(percentEncoded: false)) {
            index = flatIndex
        }
        
        index = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(document.embeddings)
        }

        // Add the data to the index
        try index.add(document.embeddings)
        
        try index.saveToFile(indexURL.path())
    }
}

