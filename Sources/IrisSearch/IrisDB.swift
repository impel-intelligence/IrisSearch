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
import IrisCommon

public enum IrisDBError: Error {
    case documentNotFound
    case noDocuments
}

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
public final class IrisDB {
    private static let databaseExtension = "irisdb"
    private static let indexExtension = "index"
    
    private var databaseURL: URL
    private var sqliteURL: URL {
        return databaseURL.appending(path: "map").appendingPathExtension("sqlite")
    }
    
    private var textIndex: FaissIndex
    private var textChunker: TextChunker
    private var textEmbedder: EmbeddingProvider
    
    public init(databaseLocation: URL, databaseName: String = "main", textEmbedder: EmbeddingProvider, textChunker: TextChunker) throws {
        databaseURL = databaseLocation.appending(path: databaseName).appendingPathExtension(IrisDB.databaseExtension)
        self.textEmbedder = textEmbedder
        self.textChunker = textChunker
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
        
        self.textIndex = try FaissIndex(indexLocation: databaseURL.appending(path: "text-index"), embeddingProvider: textEmbedder)
        
        try initializeDB()
    }
    
    private func initializeDB() throws {
        // TODO: Convert to a DatabaseMigration
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("Create Documents Table") { db in
            try db.create(table: "documents") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).unique().notNull()
            }
            
            try db.create(table: "document_pieces") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("contentType", .integer).notNull()
                table.column("textContent", .text)
                table.column("dataContent", .blob)
                table.column("embeddings", .blob).notNull()
                
                table.column("parentID", .integer).notNull()
                table.foreignKey(["parentID"], references: "documents", onDelete: .cascade)
            }

            try db.create(virtualTable: "document_pieces_ft", using: FTS5()) { table in
                table.tokenizer = .porter()
                
                table.synchronize(withTable: "document_pieces")
                table.column("id")
                table.column("parentID")
                table.column("textContent")
            }
        }
        
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        try migrator.migrate(dbQueue)
    }
}

// MARK: CRUD
extension IrisDB {
    private func chunkEmbeddableContent(_ content: EmbeddableContent) -> [EmbeddableContent] {
        switch content {
        case .text(let content):
            let textChunks = textChunker.chunk(content: content)
            return textChunks.compactMap({ EmbeddableContent.text(content: $0) })
        case .image(let content, caption: let caption):
            break
        }
        
        return [content]
    }
    
    private func embedChunk(_ chunk: EmbeddableContent) async throws -> [Float] {
        switch chunk {
        case .text(let content):
            return try await textEmbedder.embed(content: content).map({Float($0)})
        case .image(let content, let caption):
            return []
        }
    }
    
    private func createDocumentObject(uuid: UUID, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        // We need to expand `embeddableContent` to contain any data
        var pieces: [DocumentPiece] = []
        
        // Loop over all of the embeddable content we got. We may need to chunk the content, so pass it off to a chunker then create document pieces from those chunks. We are chunking in this step, since embeddable content is provided from the Digester package which does not know about model context sizes or dimensions.
        for content in embeddableContent {
            // Some content will come in too big, we need to chunk it for better search.
            let chunkedContent: [EmbeddableContent] = chunkEmbeddableContent(content)
            var embeddings: [[Float]] = []
            embeddings.reserveCapacity(chunkedContent.count)
            
            for chunk in chunkedContent {
                var chunkEmbedding: [Float] = try await embedChunk(chunk)
                
                let piece = DocumentPiece(content: chunk, embeddings: chunkEmbedding)
                pieces.append(piece)
            }
        }
                
        // Create a document object
        return IrisDocument(uuid: uuid, pieces: pieces)
    }
    
//    @discardableResult
//    public func createDocumentBatch(packages: [(uuid: UUID, content: [EmbeddableContent])]) async throws -> IrisDocument {
//        
//        return []
//    }
    
    @discardableResult
    public func createDocument(uuid: UUID, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        
        // Create a document object
        let document = try await createDocumentObject(uuid: uuid, embeddableContent: embeddableContent)

        // Insert the document into the database, capturing the inserted record (with its assigned rowID).
        let insertedDocument = try await dbQueue.write { db in
            var document = document
            try document.insert(db)
            
            // Insert document places directly from the document's mutable piece array
            for index in 0..<document.pieces.count {
                document.pieces[index].parentID = document.id
                try document.pieces[index].insert(db)
            }
            
            return document
        }

        try textIndex.addDocument(document: insertedDocument)

        return insertedDocument
    }
    
    public func readDocument(uuid: UUID) async throws -> IrisDocument? {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        
        return try await dbQueue.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { return nil }
            document.pieces = try document.request(for: IrisDocument.pieces).fetchAll(db)
            return document
        }
    }
    
    public func updateDocument(uuid: UUID, embeddableContent: [EmbeddableContent], chunker: TextChunker) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        
        // Create a document object
        let newDocument = try await createDocumentObject(uuid: uuid, embeddableContent: embeddableContent)

        let updatedDocument = try await dbQueue.write { [newDocument] db in
            // We need to get the original document so we can find set the new document's id.
            guard let existingDocument = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { throw IrisDBError.documentNotFound }

            var newDocument = newDocument
            newDocument.id = existingDocument.id // Update the ID to match the existing document.

            try newDocument.update(db)
            
            // Delete all existing document pieces
            try newDocument.request(for: IrisDocument.pieces).deleteAll(db)
            
            // Re-insert the document pieces in-place
            for index in newDocument.pieces.indices {
                newDocument.pieces[index].parentID = newDocument.id
                try newDocument.pieces[index].insert(db)
            }

            return newDocument
        }

        try textIndex.removeDocument(document: updatedDocument)
        try textIndex.addDocument(document: updatedDocument)
    }
    
    public func deleteDocument(uuid: UUID) async throws {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        
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

public struct IrisQuery {
    let text: String
    // imageData: Data
}

// MARK: Search
extension IrisDB {
    public func search(query: IrisQuery, nItems: Int = 10) async throws -> [IrisDocument] {
        let dbQueue = try DatabaseQueue(path: sqliteURL.path(percentEncoded: false))
        
        let numDocuments = try await dbQueue.read { db in
            return try DocumentPiece.fetchCount(db)
        }

        guard numDocuments > 0 else {
            throw IrisDBError.noDocuments
        }
        
        // Search for twice as many documents as the user requested to give better ranking down the line.
        let searchLimit = (nItems * 2).clamped(to: 0...numDocuments)
        
        let unicodeNormalizedQuery = query.text.precomposedStringWithCompatibilityMapping
        
        // Text index searching
        let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})

        let semanticTextIds = try textIndex.search(query: textEmbedding, kItems: searchLimit)
        
        // Image index searching
        
        // Database Search
        let syntacticTextDocuments: [SearchableDocumentPiece] = (try await dbQueue.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: unicodeNormalizedQuery) else {
                return []
            }
            
            // Search with the query interface or SQL and rank using internal BM25 function.
            let documents = try SearchableDocumentPiece
                .matching(pattern)
                .select(Column("id"), Column("textContent"), Column("parentID"), Column.rank)
                .order(Column.rank)
                .limit(searchLimit)
                .fetchAll(db)

            return documents
        })
        
        // Take just the document ids from the searched document pieces.
        let syntacticTextIds = syntacticTextDocuments.map({Int($0.id)})
        
        // Rank the document IDs using Reciprocal Ranked Fusion.
        let rankedDocumentIDs: [Int] = ReciprocalRankedFusion.rank(inputs: [semanticTextIds, syntacticTextIds])
        
        // Grab all of the documents we found from the database, they will be sorted back into rank next.
        let searchedDocuments = try await dbQueue.read { db in
            return try IrisDocument.filter(rankedDocumentIDs.contains(Column("id"))).fetchAll(db)
        }
        
        // A map from id -> rank position for O(1) rank lookup.
        let rankByID: [Int: Int] = Dictionary(uniqueKeysWithValues: rankedDocumentIDs.enumerated().map { ($1, $0) })
        
        // Pre-size an array for ordered results and place docs directly by rank
        var orderedByRank = Array<IrisDocument?>(repeating: nil, count: rankByID.count)
        
        // O(n) loop over the retrieved documents, placing each document into the array at its rank position.
        for doc in searchedDocuments {
            if let rawID = doc.id, let rank = rankByID[Int(rawID)] , rank < orderedByRank.count {
                orderedByRank[rank] = doc
            }
        }
        
        // Compact the rank order list, to remove an documents that were not found.
        let compactOrdered = orderedByRank.compactMap { $0 }
        
        // Limit the kItems the user requested to the number of documents we found.
        let limit = nItems.clamped(to: 0...compactOrdered.count)
        return Array(compactOrdered.prefix(upTo: limit))
    }
}

