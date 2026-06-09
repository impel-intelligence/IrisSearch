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
}

// MARK: CRUD
extension IrisDB {
    private func createDocumentObject(uuid: UUID, content: String, chunks: [String]) async throws -> IrisDocument {
        // Create an array to store the embeddings for each content chunk. Storing chunk embeddings results in more accurate semantic search in longer documents.
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(chunks.count)
        
        for chunk in chunks {
            // Embed the content chunk, and convert from a double to a float to match FAISS
            var chunkEmbedding: [Float] = try await embeddingProvider.embed(content: chunk).map({Float($0)})
            
            // Normalize the vector into a format suited for the L2 search metric.
            faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &chunkEmbedding)
            
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
        
        try await refreshIndex(for: document)
        try await addDocumentToGlobalIndex(document: document)
        
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
        
        // Remove the existing index, and create a new one
        try await refreshIndex(for: newDocument)
        
        // Remove the document we just updated from the global index. New document has the same ID so we can pass it in, instead of existing document.
        try await removeDocumentFromGlobalIndex(document: newDocument)
        try await addDocumentToGlobalIndex(document: newDocument)
    }
    
    public func deleteDocument(uuid: UUID) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path())
        
        let tmpDocument = try await dbQueue.read { db in
            return try IrisDocument.fetchOne(db, key: ["uuid": uuid])
        }
        
        _ = try await dbQueue.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": uuid])
        }
        
        let indexURL = IndexLocation.document(uuid: uuid).filePath(in: indexDirectory)
        try FileManager.default.removeItem(at: indexURL)
        
        // Remove the document we just deleted from the global index
        if let tmpDocument {
            try await removeDocumentFromGlobalIndex(document: tmpDocument)
        }
    }
}

// MARK: Index Management
extension IrisDB {
    private func getGlobalIndex() throws -> IDMap {
        let indexURL = IndexLocation.global.filePath(in: indexDirectory)
        
        if FileManager.default.fileExists(atPath: indexURL.path()),
           let flatIndex = try? IDMap.from(indexURL.path(percentEncoded: false)) {
            return flatIndex
        } else {
            let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
            return try IDMap(subIndex: coreIndex)
        }
    }
    
    private func removeDocumentFromGlobalIndex(document: IrisDocument) async throws {
        let indexURL = IndexLocation.global.filePath(in: indexDirectory)

        guard let documentID = document.id else { throw IrisDBError.documentNotFound }

        let index: IDMap = try getGlobalIndex()

        // Delete all indices related to this document.
        try index.removeIds([Int(documentID)])
        
        // Save the global index
        try index.saveToFile(indexURL.path())
    }
    
    private func addDocumentToGlobalIndex(document: IrisDocument) async throws {
        let indexURL = IndexLocation.global.filePath(in: indexDirectory)

        guard let documentID = document.id else { throw IrisDBError.documentNotFound }

        let index: IDMap = try getGlobalIndex()

        var embeddings: [[Float]] = []
        var ids: [Int] = []

        for embedding in document.embeddings {
            embeddings.append(embedding)
            ids.append(Int(documentID))
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
            guard let documentID = document.id else { continue }
            // For each embedding in the document, add it with the document's rowID as its ID
            for embedding in document.embeddings {
                embeddings.append(embedding)
                ids.append(Int(documentID))
            }
        }
        
        let index: IDMap = try getGlobalIndex()

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
        
        // If an index already exists, remove it so we can create a new one.
        if FileManager.default.fileExists(atPath: indexURL.path()) {
            try FileManager.default.removeItem(at: indexURL)
        }
        
        // Use a flat index for single document indices as we do not need anything faster.
        var index = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(document.embeddings)
        }

        // Add the data to the index
        try index.add(document.embeddings)
        
        try index.saveToFile(indexURL.path())
    }
}

