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
/// - text-indices
///     - all.index
///     - doc-1.index
///     - doct-2.index
/// - image-indices
///     - all.index
///     - doc-1.index
///     - doc-3.index
/// - map.sqlite

final class IrisDocument: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName: String = "documents"
    
    nonisolated(unsafe) var id: Int64?
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

enum IrisDBError: Error {
    case documentNotFound
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
    
    private var databaseURL: URL
    private var sqliteURL: URL {
        return databaseURL.appending(path: "map").appendingPathExtension("sqlite")
    }
    
    private var textIndex: FaissIndex
    private var textEmbedder: EmbeddingProvider
    
    init(databaseLocation: URL, databaseName: String = "main", textEmbedder: EmbeddingProvider) throws {
        databaseURL = databaseLocation.appending(path: databaseName).appendingPathExtension(IrisDB.databaseExtension)
        self.textEmbedder = textEmbedder
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path()) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
        
        self.textIndex = try FaissIndex(indexLocation: databaseURL.appending(path: "text-index"), embeddingProvider: textEmbedder)
        
        try initializeDB()
    }
    
    private func initializeDB() throws {
        print(sqliteURL)
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
}

// TODO: We need to support images as well as text, so people can search for figures.
// MARK: CRUD
extension IrisDB {
    private func createDocumentObject(uuid: UUID, content: String, chunks: [String]) async throws -> IrisDocument {
        // Create an array to store the embeddings for each content chunk. Storing chunk embeddings results in more accurate semantic search in longer documents.
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(chunks.count)
        
        for chunk in chunks {
            // Embed the content chunk, and convert from a double to a float to match FAISS
            var chunkEmbedding: [Float] = try await textEmbedder.embed(content: chunk).map({Float($0)})
            
            // Normalize the vector into a format suited for the L2 search metric.
            faiss_fvec_renorm_L2(textEmbedder.dimension, 1, &chunkEmbedding)
            
            embeddings.append(chunkEmbedding)
        }
        
        // Create a document object
        return IrisDocument(uuid: uuid, content: content, embeddings: embeddings)
    }
    
    
    @discardableResult
    public func createDocument(uuid: UUID, content: String, chunker: ContentChunker) async throws -> IrisDocument {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        let contentChunks = chunker.chunk(content: content)
        
        // Create a document object
        let document = try await createDocumentObject(uuid: uuid, content: content, chunks: contentChunks)
        
        // Insert into the document into the database
        try await dbQueue.write { db in
            try document.insert(db)
        }
        
        try textIndex.addDocument(document: document)
        
        return document
    }
    
    public func readDocument(uuid: UUID) async throws -> IrisDocument? {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        return try await dbQueue.read { db in
            return try IrisDocument.fetchOne(db, key: ["uuid": uuid])
        }
    }
    
    public func updateDocument(uuid: UUID, content: String, chunker: ContentChunker) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        let contentChunks = chunker.chunk(content: content)
        
        // Create a document object
        let newDocument = try await createDocumentObject(uuid: uuid, content: content, chunks: contentChunks)

        try await dbQueue.write { [newDocument] db in
            // We need to get the original document so we can find set the new document's id.
            guard let existingDocument = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { throw IrisDBError.documentNotFound }

            newDocument.id = existingDocument.id // Update the ID to match the existing document.

            try newDocument.update(db)
        }
        
        try textIndex.removeDocument(document: newDocument)
        try textIndex.addDocument(document: newDocument)
    }
    
    public func deleteDocument(uuid: UUID) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        let tmpDocument = try await dbQueue.read { db in
            return try IrisDocument.fetchOne(db, key: ["uuid": uuid])
        }
        
        _ = try await dbQueue.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": uuid])
        }

        // Remove the document we just deleted from the global index
        if let tmpDocument {
            try textIndex.removeDocument(document: tmpDocument)
        }
    }
}
