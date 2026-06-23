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
public actor IrisDB {
    private static let databaseExtension = "irisdb"
    private static let indexExtension = "index"
    
    private let databaseURL: URL
    private let textIndex: FaissIndex
    private let textChunker: TextChunker
    private let textEmbedder: EmbeddingProvider
    
    private let dbPool: DatabasePool
    private let writeExecutor: KeyedExecutor<UUID> = KeyedExecutor()
    
    public init(databaseLocation: URL, databaseName: String = "main", textEmbedder: EmbeddingProvider, textChunker: TextChunker) throws {
        databaseURL = databaseLocation.appending(path: databaseName).appendingPathExtension(IrisDB.databaseExtension)

        self.textEmbedder = textEmbedder
        self.textChunker = textChunker
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
        
        self.textIndex = try FaissIndex(indexLocation: databaseURL.appending(path: "text-index"), embeddingProvider: textEmbedder)

        let sqliteURL = databaseURL.appending(path: "map").appendingPathExtension("sqlite")

        // Pin the pool's reader/writer queues to a fixed QoS. Otherwise they adopt the priority of the calling thread. This can lead to priority inversion at runtime when a foreground thread calls IrisDB and it is doing other backend pool work.
        var configuration = Configuration()
        configuration.qos = .userInitiated
        dbPool = try DatabasePool(path: sqliteURL.path(percentEncoded: false), configuration: configuration)

        try initializeDB()
    }
    
    private nonisolated func initializeDB() throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("Create Documents Table") { db in
            try db.create(table: IrisDocument.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).unique().notNull()
                table.column("title", .text).notNull()
                table.column("description", .text).notNull()
            }
            
            try db.create(virtualTable: SearchableDocument.databaseTableName, using: FTS5()) { table in
                table.tokenizer = .porter()
                
                table.synchronize(withTable: IrisDocument.databaseTableName)
                table.column("id")
                table.column("title")
                table.column("description")
            }

            try db.create(table: DocumentPiece.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("contentType", .integer).notNull()
                table.column("textContent", .text)
                table.column("dataContent", .blob)
                table.column("embeddings", .blob).notNull()
                
                table.column("parentID", .integer).notNull()
                table.foreignKey(["parentID"], references: "documents", onDelete: .cascade)
            }

            try db.create(virtualTable: SearchableDocumentPiece.databaseTableName, using: FTS5()) { table in
                table.tokenizer = .porter()
                
                table.synchronize(withTable: DocumentPiece.databaseTableName)
                table.column("id")
                table.column("parentID")
                table.column("textContent")
            }
        }
        
        try migrator.migrate(dbPool)
    }
}

// MARK: CRUD
// Read operations
extension IrisDB {
    public func readDocument(uuid: UUID) async throws -> IrisDocument? {
        return try await dbPool.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { return nil }
            document.pieces = try document.request(for: IrisDocument.pieces).fetchAll(db)
            return document
        }
    }
    
    public func readDocuments(uuids: [UUID]) async throws -> [IrisDocument] {
        return try await dbPool.read { db in
            let keys = uuids.map({ ["uuid": $0] })
            var documents = try IrisDocument.fetchAll(db, keys: keys)
            
            for index in 0..<documents.count {
                documents[index].pieces = try documents[index].request(for: IrisDocument.pieces).fetchAll(db)
            }
            
            return documents
        }
    }
}

// Create, update and delete actions
extension IrisDB {
    private func chunkEmbeddableContent(_ content: EmbeddableContent) -> [EmbeddableContent] {
        switch content {
        case .text(let content):
            let textChunks = textChunker.chunk(content: content)
            return textChunks.compactMap({ EmbeddableContent.text(content: $0) })
        case .image(_, _):
            break
        }
        
        return [content]
    }
    
    private func embedChunk(_ chunk: EmbeddableContent) async throws -> [Float] {
        switch chunk {
        case .text(let content):
            return try await textEmbedder.embed(content: content).map({Float($0)})
        case .image(_, _):
            return []
        }
    }
    
    private func createDocumentObject(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        // We need to expand `embeddableContent` to contain any data
        var pieces: [DocumentPiece] = []
        
        // Loop over all of the embeddable content we got. We may need to chunk the content, so pass it off to a chunker then create document pieces from those chunks. We are chunking in this step, since embeddable content is provided from the Digester package which does not know about model context sizes or dimensions.
        for content in embeddableContent {
            // Some content will come in too big, we need to chunk it for better search.
            let chunkedContent: [EmbeddableContent] = chunkEmbeddableContent(content)
            var embeddings: [[Float]] = []
            embeddings.reserveCapacity(chunkedContent.count)
            
            for chunk in chunkedContent {
                let chunkEmbedding: [Float] = try await embedChunk(chunk)
                let piece = DocumentPiece(content: chunk, embeddings: chunkEmbedding)
                pieces.append(piece)
            }
        }
                
        // Create a document object
        return IrisDocument(uuid: uuid, title: title, description: description, pieces: pieces)
    }
    
    /// Creates a document entry in the database.
    /// - Parameters:
    ///   - uuid: The UUID of the document to create.
    ///   - title: The title of the document, used for full text search.
    ///   - description: A description of the document, used for full text search.
    ///   - embeddableContent: The embeddable content, usually created by a ``Digester``
    /// - Returns: A populated ``IrisDocument``, with an entry in the SQLite database & the FAISS index.
    @discardableResult
    public func createDocument(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        return try await writeExecutor.run(uuid) {
            // Call back into the IrisDB actor to perform the create document action. Ensures that the actual creation code runs within the actor's context and not on the task created by writeExecutor.
            return try await self.performCreateDocument(uuid: uuid, title: title, description: description, embeddableContent: embeddableContent)
        }
    }
    
    /// An internal function that handles actually creating documents.
    ///
    /// ``createDocument(uuid:title:description:embeddableContent:)`` submits this function to the writeExecutor to serialize database actions for the given `uuid`.
    /// - Parameters:
    ///   - uuid: The UUID of the document to create.
    ///   - title: The title of the document, used for full text search.
    ///   - description: A description of the document, used for full text search.
    ///   - embeddableContent: The embeddable content, usually created by a ``Digester``
    /// - Returns: A populated ``IrisDocument``, with an entry in the SQLite database & the FAISS index.
    private func performCreateDocument(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        // Create a document object
        let document = try await self.createDocumentObject(uuid: uuid, title: title, description: description, embeddableContent: embeddableContent)
        
        // Insert the document into the database, capturing the inserted record (with its assigned rowID).
        let insertedDocument = try await self.dbPool.write { db in
            var document = document
            try document.insert(db)
            
            // Insert document places directly from the document's mutable piece array
            for index in 0..<document.pieces.count {
                document.pieces[index].parentID = document.id
                try document.pieces[index].insert(db)
            }
            
            return document
        }
        
        try self.textIndex.addDocument(document: insertedDocument)
        
        return insertedDocument

    }
    
    /// Updates a document's entry in the database.
    /// - Parameters:
    ///   - uuid: The UUID of the document to update.
    ///   - title: The new title of the document.
    ///   - description: The new description for the document
    ///   - embeddableContent: The new embeddable content, usually created by a ``Digester``
    public func updateDocument(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws {
        try await writeExecutor.run(uuid) {
            try await self.performUpdateDocument(uuid: uuid, title: title, description: description, embeddableContent: embeddableContent)
        }
    }
    
    /// An internal function that handles actually updating 
    /// documents.
    ///
    /// ``updateDocument(uuid:title:description:embeddableContent:)`` submits this function to the writeExecutor to serialize database actions for the given `uuid`.
    /// - Parameters:
    ///   - uuid: The UUID of the document to update.
    ///   - title: The new title of the document.
    ///   - description: The new description for the document
    ///   - embeddableContent: The new embeddable content, usually created by a ``Digester``
    private func performUpdateDocument(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws {
        // Create a document object
        let newDocument = try await createDocumentObject(uuid: uuid, title: title, description: description, embeddableContent: embeddableContent)
        
        let updatedDocument = try await dbPool.write { [newDocument] db in
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
    
    
    /// Delete a document by `uuid`.
    /// - Parameter uuid: The UUID of the document to delete from the database.
    public func deleteDocument(uuid: UUID) async throws {
        try await writeExecutor.run(uuid) {
            try await self.performDeleteDocument(uuid: uuid)
        }
    }
    
    /// Delete a document by `uuid`.
    ///
    /// ``deleteDocument(uuid:)`` submits this function to the writeExecutor to serialize database actions for the given `uuid`.
    /// - Parameter uuid: The UUID of the document to delete from the database.
    private func performDeleteDocument(uuid: UUID) async throws {
        let tmpDocument = try await dbPool.read { db in
            return try IrisDocument.fetchOne(db, key: ["uuid": uuid])
        }
        
        _ = try await dbPool.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": uuid])
        }
        
        // Remove the document we just deleted from the global index
        if let tmpDocument {
            try textIndex.removeDocument(document: tmpDocument)
        }
    }
}

// MARK: Search
extension IrisDB {
    public func search(query: IrisQuery, nItems: Int = 10, within documentIDs: [UUID]) async throws -> [IrisDocument] {
        let documents = try await readDocuments(uuids: documentIDs)
        
        guard !documents.isEmpty else { throw IrisDBError.noDocuments }
        
        // Get the total number of pieces the requested documents make up of.
        let totalPieces = documents.reduce(0) { partialResult, document in
            partialResult + document.pieces.count
        }
        
        // Search for twice as many items as the user requested to give better ranking down the line.
        let searchLimit = (nItems * 2).clamped(to: 0...totalPieces)
        
        let unicodeNormalizedQuery = query.text.precomposedStringWithCompatibilityMapping
        
        // Text index searching
        let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})
        
        let semanticTextIds = try textIndex.search(query: textEmbedding, kItems: searchLimit)

        return []
    }
    
    public func search(query: IrisQuery, nItems: Int = 10, ranking: FusionAlgorithm = .reciprocalRankedFusion) async throws -> [IrisDocument] {
        let maximumPieces = try await dbPool.read { db in
            return try DocumentPiece.fetchCount(db)
        }

        guard maximumPieces > 0 else { throw IrisDBError.noDocuments }
        
        // Search for twice as many items as the user requested to give better ranking down the line.
        let searchLimit = (nItems * 2).clamped(to: 0...maximumPieces)
        
        let unicodeNormalizedQuery = query.text.precomposedStringWithCompatibilityMapping
        
        // Text index searching
        let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})

        let semanticTextResults: [(id: Int, distance: Float)] = try textIndex.search(query: textEmbedding, kItems: searchLimit)
        
        // Document Database Search
        let syntacticTextDocuments: [SearchableDocument] = (try await dbPool.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: unicodeNormalizedQuery) else {
                return []
            }
            
            // Search with the query interface or SQL and rank using internal BM25 function.
            let documents = try SearchableDocument
                .matching(pattern)
                .select(Column("id"), Column("title"), Column("description"), Column.rank)
                .order(Column.rank)
                .limit(searchLimit)
                .fetchAll(db)
            
            return documents
        })

        // Document Piece Database Search
        let syntacticTextDocumentPieces: [SearchableDocumentPiece] = (try await dbPool.read { db in
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
                
        // Rank the document IDs using the selected ranking functions.
        let rankedDocumentIDs: [Int]
        
        switch ranking {
        case .relativeScoreFusion:
            // Take document ids and their BM25 score
            let syntacticDocumentInput: [(Int, Double)] = syntacticTextDocuments.map({ (Int($0.id), $0.rank) })
            let syntacticDocumentPieceInput: [(Int, Double)] = syntacticTextDocumentPieces.map({ (Int($0.id), $0.rank) })
            let semanticSearchInput: [(Int, Double)] = semanticTextResults.map({ ($0.id, Double($0.distance)) })

            rankedDocumentIDs = try RelativeScoreFusion.rank(inputs: [
                syntacticDocumentInput,
                syntacticDocumentPieceInput,
                semanticSearchInput
            ], weights: [2/3, 1/6, 1/6])
        case .reciprocalRankedFusion:
            // Take just the document ids from the searched document pieces
            let syntacticDocumentIds = syntacticTextDocuments.map { Int($0.id) }
            
            // Take just the document ids from the searched document pieces.
            let syntacticDocumentPieceIds = syntacticTextDocumentPieces.map({Int($0.id)})

            // Take just ordered IDs from the semantic search results.
            let semanticTextIds = semanticTextResults.flatMap({$0.id})
            
            rankedDocumentIDs = ReciprocalRankedFusion.rank(inputs: [
                semanticTextIds,
                syntacticDocumentPieceIds,
                syntacticDocumentIds
            ])
        }
        
        // Grab all of the documents we found from the database, they will be sorted back into rank next.
        let searchedDocuments = try await dbPool.read { db in
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

