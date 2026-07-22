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
    private let textEmbedder: EmbeddingProvider
    
    private let dbPool: DatabasePool
    private let writeExecutor: KeyedExecutor<UUID> = KeyedExecutor()
    
    public let contextSize: Int = 512
    
    public init(databaseLocation: URL, databaseName: String = "main", textEmbedder: EmbeddingProvider) throws {
        databaseURL = databaseLocation.appending(path: databaseName).appendingPathExtension(IrisDB.databaseExtension)

        self.textEmbedder = textEmbedder
        
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
                table.column("title", .text).unique().notNull()
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
                table.column("embeddings", .blob).notNull() // Removed in a later migration
                
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
        
        migrator.registerMigration("Add Document Locations") { db in
            try db.alter(table: DocumentPiece.databaseTableName) { table in
                table.add(column: "sequenceIndex", .integer)
                table.add(column: "documentLength", .integer)
                table.add(column: "documentAnchor", .blob)
            }
        }
        
        migrator.registerMigration("Remove Embeddings Column") { db in
            try db.alter(table: DocumentPiece.databaseTableName) { table in
                table.drop(column: "embeddings")
            }
        }
        
        try migrator.migrate(dbPool)
    }
}

// MARK: CRUD
// Read operations
extension IrisDB {
    public func readPiece(uuid: UUID, pieceSequence: Int) async throws -> DocumentPiece? {
        return try await dbPool.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { return nil }
            
            document.pieces = try document.request(for: IrisDocument.pieces)
                .filter({ pieceSequence == $0.sequenceIndex })
                .limit(1)
                .fetchAll(db)
            
            return document.pieces.first
        }
    }
    
    public func readPieceContext(documentTitle: String, pieceSequenceIndex: Int, before: Int, after: Int) async throws -> [DocumentPiece] {
        return try await dbPool.read { db in
            // The range of pieces that we want to grab
            let sequenceRange = (pieceSequenceIndex - before)..<(pieceSequenceIndex + after)
            guard var document = try IrisDocument.fetchOne(db, key: ["title": documentTitle]) else {
                Log.logger.warning("Could not find a document with title \(documentTitle)")
                return []
            }
            
            document.pieces = try document.request(for: IrisDocument.pieces)
                .filter({ sequenceRange.contains($0.sequenceIndex) })
                .fetchAll(db)
            
            return document.pieces
        }
    }
    
    public func readDocument(title: String, pieceSequenceRange: Range<Int>) async throws -> IrisDocument? {
        return try await dbPool.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["title": title]) else {
                Log.logger.warning("Could not find a document with title \(title)")
                return nil
            }
            document.pieces = try document.request(for: IrisDocument.pieces)
                .filter({ pieceSequenceRange.contains($0.sequenceIndex) })
                .fetchAll(db)
            return document
        }
    }

    public func readDocument(title: String) async throws -> IrisDocument? {
        return try await dbPool.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["title": title]) else {
                Log.logger.warning("Could not find a document with title \(title)")
                return nil
            }
            document.pieces = try document.request(for: IrisDocument.pieces).fetchAll(db)
            return document
        }
    }

    public func readDocument(uuid: UUID) async throws -> IrisDocument? {
        return try await dbPool.read { db in
            guard var document = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else {
                Log.logger.warning("Could not find a document", metadata: ["uuid": "\(uuid.uuidString)"])
                return nil
            }
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
    private func embedChunk(_ chunk: EmbeddableContent) async throws -> [Float] {
        switch chunk {
        case .text(let content, _):
            return try await textEmbedder.embed(content: content).map({Float($0)})
        case .image(_, _, _):
            // TODO: Image Embedding
            Log.logger.info("Not embedding image since it is not yet supported")
            return []
        }
    }
    
    private func createDocumentObject(uuid: UUID, title: String, description: String, embeddableContent: [EmbeddableContent]) async throws -> IrisDocument {
        // We need to expand `embeddableContent` to contain any data
        var pieces: [DocumentPiece] = []
        
        // Loop over all of the embeddable content we got and send it to the embedder for that content.
        for chunk in embeddableContent {
            let chunkEmbedding: [Float] = try await embedChunk(chunk)
            let piece = DocumentPiece(content: chunk, embeddings: chunkEmbedding)
            pieces.append(piece)
        }
                
        // Create a document object
        return IrisDocument(uuid: uuid, title: title, description: description, pieces: pieces)
    }
    
    /// Creates a document entry in the database.
    /// - Parameters:
    ///   - uuid: The UUID of the document to create.
    ///   - title: The title of the document, used for full text search.
    ///   - description: A description of the document, used for full text search.
    ///   - embeddableContent: The embeddable content, usually created by a `FileDigester`
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
        
        // Insert the document into faiss.
        do {
            try self.textIndex.addDocument(document: insertedDocument)
        } catch {
            // If adding to the index fails, delete the inserted document.
            _ = try await self.dbPool.write { db in
                try insertedDocument.delete(db)
            }
            
            Log.logger.error("Failed to create document \(uuid): \(title)", metadata: ["error": "\(error)"])
            // Then re-throw the error.
            throw error
        }
        
        return insertedDocument
    }
    
    /// Updates a document's entry in the database.
    /// - Parameters:
    ///   - uuid: The UUID of the document to update.
    ///   - title: The new title of the document.
    ///   - description: The new description for the document
    ///   - embeddableContent: The new embeddable content, usually created by a `FileDigester`
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
        
        let (updatedDocument, oldPieceIDs) = try await dbPool.write { [newDocument] db -> (IrisDocument, [Int]) in
            // We need to get the original document so we can find set the new document's id.
            guard let existingDocument = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { throw IrisDBError.documentNotFound }

            let oldPieceIDs = try existingDocument
                .request(for: IrisDocument.pieces)
                .fetchAll(db)
                .compactMap(\.id)
                .map({ Int($0) })

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

            return (newDocument, oldPieceIDs)
        }

        try textIndex.removeDocument(documentID: uuid, pieceIDs: oldPieceIDs)
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
            guard var doc = try IrisDocument.fetchOne(db, key: ["uuid": uuid]) else { return IrisDocument?.none }
            doc.pieces = try doc.request(for: IrisDocument.pieces).fetchAll(db)
            return doc
        }
        
        _ = try await dbPool.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": uuid])
        }
        
        // Remove the document we just deleted from the global index
        if let tmpDocument {
            let oldIDs = tmpDocument.pieces.compactMap(\.id).map({ Int($0) })
            try textIndex.removeDocument(documentID: uuid, pieceIDs: oldIDs)
        }
    }
}

public struct SearchResult: Sendable {
    public let document: IrisDocument
    public let importantPieces: [DocumentPiece]
}

// MARK: Search
extension IrisDB {
    public func search(within uuid: UUID, query: IrisQuery, nItems: Int = 10, ranking: FusionAlgorithm = .reciprocalRankedFusion) async throws -> SearchResult {
        let document = try await readDocument(uuid: uuid)
        guard let document else { throw IrisDBError.noDocuments }
                
        // Search for twice as many items as the user requested to give better ranking down the line.
        let searchLimit = (nItems * 2).clamped(to: 0...document.pieces.count)
        
        let unicodeNormalizedQuery = query.text.precomposedStringWithCompatibilityMapping
        
        // Text index searching
        let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})
        
        let semanticTextPieces: [(id: Int, distance: Float)] = try textIndex.search(query: textEmbedding, kItems: searchLimit, collection: uuid)
        
        let semanticDocumentPieces = try await dbPool.read { db in
            return try DocumentPiece
                .filter(semanticTextPieces.map(\.id).contains(Column("id")))
                .fetchAll(db)
        }

        // Document Piece Database Search
        let syntacticTextDocumentPieces: [SearchableDocumentPiece] = (try await dbPool.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: unicodeNormalizedQuery) else {
                Log.logger.warning("Could not create an FTS5 Pattern for \(unicodeNormalizedQuery)")
                return []
            }
            
            // Search with the query interface or SQL and rank using internal BM25 function.
            let documents = try SearchableDocumentPiece
                .matching(pattern)
                .select(Column("id"), Column("textContent"), Column("parentID"), Column.rank)
                .filter(Column("parentID") == document.id)
                .order(Column.rank)
                .limit(searchLimit)
                .fetchAll(db)
            
            return documents
        })
        

        // Rank the document pieces
        let rankedPieceIDs = try pieceRanking(
            ranking: ranking,
            syntacticTextDocumentPieces: syntacticTextDocumentPieces,
            semanticTextPieces: semanticTextPieces,
            semanticDocumentPieces: semanticDocumentPieces
        )
        
        // Save the ranking (list index) for every piece ID. Will be used for reconstructing the ranking after database fetches.
        let pieceRanksByID: [Int: Int] = Dictionary(uniqueKeysWithValues: rankedPieceIDs.enumerated().map { ($1, $0) })
                
        // Any pieces that were actually surfaced by the piece searching
        let surfacedPieceIDs = Set(semanticTextPieces.map(\.id) + syntacticTextDocumentPieces.map { Int($0.id) })
        
        // Take the top n ranked pieces.
        let limitedPieceIDs = Array(surfacedPieceIDs.prefix(nItems))
        
        let searchedPieces = try await dbPool.read { db in
            return try DocumentPiece.filter(limitedPieceIDs.contains(Column("id"))).fetchAll(db)
        }
        
        var orderedByRank = Array<DocumentPiece?>(repeating: nil, count: limitedPieceIDs.count)
        
        // O(n) loop over the retrieved pieces, placing each piece into the array at its rank position.
        for piece in searchedPieces {
            if let rawID = piece.id, let rank = pieceRanksByID[Int(rawID)] , rank < orderedByRank.count {
                orderedByRank[rank] = piece
            }
        }
        
        let orderedPieces = orderedByRank.compactMap({$0})

        return SearchResult(
            document: document,
            importantPieces: orderedPieces
        )
    }
    
    public func search(query: IrisQuery, nItems: Int = 10, ranking: FusionAlgorithm = .reciprocalRankedFusion) async throws -> [SearchResult] {
        let maximumPieces = try await dbPool.read { db in
            return try DocumentPiece.fetchCount(db)
        }
        
        guard maximumPieces > 0 else { throw IrisDBError.noDocuments }
        
        // Search for twice as many items as the user requested to give better ranking down the line.
        let searchLimit = (nItems * 2).clamped(to: 0...maximumPieces)
        
        let unicodeNormalizedQuery = query.text.precomposedStringWithCompatibilityMapping
        
        // MARK: Searching
        // Text index searching
        let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})
        
        let semanticTextPieces: [(id: Int, distance: Float)] = try textIndex.search(query: textEmbedding, kItems: searchLimit)
       
        let semanticDocumentPieces = try await dbPool.read { db in
            return try DocumentPiece
                .filter(semanticTextPieces.map(\.id).contains(Column("id")))
                .fetchAll(db)
        }
        

        // Document Piece Database Search
        let syntacticTextDocumentPieces: [SearchableDocumentPiece] = (try await dbPool.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: unicodeNormalizedQuery) else {
                Log.logger.warning("Could not create an FTS5 Pattern for \(unicodeNormalizedQuery)")
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
        
        // Search documents by their title and description.
        let syntacticTextDocuments: [SearchableDocument] = (try await dbPool.read { db in
            guard let pattern = FTS5Pattern(matchingAnyTokenIn: unicodeNormalizedQuery) else {
                Log.logger.warning("Could not create an FTS5 Pattern for \(unicodeNormalizedQuery)")
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
        
        // Ranking
        let rankedPieceIDs = try pieceRanking(
            ranking: ranking,
            syntacticTextDocumentPieces: syntacticTextDocumentPieces,
            semanticTextPieces: semanticTextPieces,
            semanticDocumentPieces: semanticDocumentPieces
        )
        
        // Map Piece ID to the Parent Document ID
        var pieceParentDocuments: [Int: Int] = [:]
        
        // Map semantic results
        for piece in semanticDocumentPieces {
            guard let id = piece.id, let parentID = piece.parentID else { continue }
            pieceParentDocuments[Int(id)] = Int(parentID)
        }
        
        // Map syntactic (FTS5) results
        for piece in syntacticTextDocumentPieces {
            pieceParentDocuments[Int(piece.id)] = Int(piece.parentID)
        }
        
        // Array tracking Document ID: Smallest Piece Distance
        var semanticDocumentsWithBestScore: [Int: Double] = [:]
        
        for piece in semanticTextPieces {
            guard let parentID = pieceParentDocuments[piece.id] else {
                Log.logger.warning("\(piece.id) does not exist in the parent documents dictionary.")
                continue
            }
            let currentDistance = semanticDocumentsWithBestScore[parentID, default: -.greatestFiniteMagnitude]
            semanticDocumentsWithBestScore[parentID] = max(currentDistance, Double(piece.distance))
        }
        
        // Array tracking Document ID: Smallest Rank
        var syntacticDocumentsWithBestScore: [Int: Double] = [:]
        
        for piece in syntacticTextDocumentPieces {
            let parentID: Int = Int(piece.parentID)
            let currentRank: Double = syntacticDocumentsWithBestScore[parentID, default: -.greatestFiniteMagnitude]
            syntacticDocumentsWithBestScore[parentID] = max(currentRank, -piece.rank)
        }
        
        let rankedDocumentIDs = try documentRanking(
            ranking: ranking,
            semanticDocumentsWithBestScore: semanticDocumentsWithBestScore,
            syntacticDocumentsWithBestScore: syntacticDocumentsWithBestScore,
            syntacticTextDocuments: syntacticTextDocuments
        )
        
        // Save the ranking (list index) for every piece ID. Will be used for reconstructing the ranking after database fetches.
        let pieceRanksByID: [Int: Int] = Dictionary(uniqueKeysWithValues: rankedPieceIDs.enumerated().map { ($1, $0) })
        
        // Save the ranking (list index) for every document ID. Will be used for reconstructing the ranking after database fetches.
        let documentRanksByID: [Int: Int] = Dictionary(uniqueKeysWithValues: rankedDocumentIDs.enumerated().map { ($1, $0) })
        
        // Any pieces that were actually surfaced by the piece searching
        let surfacedPieceIDs = Set(semanticTextPieces.map(\.id) + syntacticTextDocumentPieces.map { Int($0.id) })
        
        // Take the top n ranked documents.
        let limitedDocumentIDs = Array(rankedDocumentIDs.prefix(nItems))
        
        // Find all of the documents that match the limited documents we just made, and load their pieces.
        let searchedDocuments = try await dbPool.read { db in
            return try IrisDocument.filter(limitedDocumentIDs.contains(Column("id"))).fetchAll(db)
        }
        
        var orderedByRank = Array<IrisDocument?>(repeating: nil, count: limitedDocumentIDs.count)
        
        // O(n) loop over the retrieved documents, placing each document into the array at its rank position.
        for doc in searchedDocuments {
            if let rawID = doc.id, let rank = documentRanksByID[Int(rawID)] , rank < orderedByRank.count {
                orderedByRank[rank] = doc
            }
        }
        
        let orderedDocuments = orderedByRank.compactMap({$0})
        
        let searchResults: [SearchResult] = try await dbPool.read { db in
            var results: [SearchResult] = []
            results.reserveCapacity(orderedDocuments.count)
            
            for document in orderedDocuments {
                let pieces = try document
                    .request(for: IrisDocument.pieces)
                    .filter(surfacedPieceIDs.contains(Column("id")))
                    .fetchAll(db)
                
                // Order the document's pieces by relevance using an O(n) loop.
                var orderedByRank = Array<DocumentPiece?>(repeating: nil, count: pieceRanksByID.count)
                
                for piece in pieces {
                    if let rawID = piece.id, let rank = pieceRanksByID[Int(rawID)] , rank < orderedByRank.count {
                        orderedByRank[rank] = piece
                    }
                }
                
                let orderedPieces = orderedByRank.compactMap({$0})
                results.append(SearchResult(document: document, importantPieces: orderedPieces))
            }
            
            return results
        }
        
        return searchResults
    }
    
    private func pieceRanking(
        ranking: FusionAlgorithm,
        syntacticTextDocumentPieces: [SearchableDocumentPiece],
        semanticTextPieces: [(id: Int, distance: Float)],
        semanticDocumentPieces: [DocumentPiece]
    ) throws -> [Int] {
        // Rank the piece IDs using the selected ranking functions.
        let rankedPieceIDs: [Int]
        
        switch ranking {
        case .relativeScoreFusion:
            // Take document ids and their BM25 score. Use negative BM25 rank since lower is better out of FTS5.
            let syntacticDocumentPieceInput: [(Int, Double)] = syntacticTextDocumentPieces.map({ (Int($0.id), -$0.rank) })
            let semanticSearchInput: [(Int, Double)] = semanticTextPieces.map({ ($0.id, Double($0.distance)) })
            
            rankedPieceIDs = try RelativeScoreFusion.rank(inputs: [
                syntacticDocumentPieceInput,
                semanticSearchInput
            ], weights: [1/2, 1/2])
        case .reciprocalRankedFusion:
            // Take just the document ids from the searched document pieces.
            let syntacticDocumentPieceIds = syntacticTextDocumentPieces.map({Int($0.id)})
            
            // Take just ordered IDs from the semantic search results.
            let semanticTextIds = semanticTextPieces.map(\.id)
            
            rankedPieceIDs = ReciprocalRankedFusion.rank(inputs: [
                semanticTextIds,
                syntacticDocumentPieceIds,
            ])
        }

        return rankedPieceIDs
    }
    
    // (rankedPieceIDs: [Int], semanticDocumentsWithBestScore: [Int: Double], syntacticDocumentsWithBestScore: [Int: Double])
    private func documentRanking(
        ranking: FusionAlgorithm,
        semanticDocumentsWithBestScore: [Int: Double],
        syntacticDocumentsWithBestScore: [Int: Double],
        syntacticTextDocuments: [SearchableDocument]
    ) throws -> [Int] {
        let rankedDocumentIDs: [Int]
        
        switch ranking {
        case .relativeScoreFusion:
            // Take document ids and their BM25 score. Use negative BM25 rank since lower is better out of FTS5.
            let syntacticDocumentPieceInput: [(Int, Double)] = syntacticDocumentsWithBestScore.map { (id: $0.key, score: $0.value) }
            let semanticSearchInput: [(Int, Double)] = semanticDocumentsWithBestScore.map { (id: $0.key, score: $0.value) }
            let documentSearchInput: [(Int, Double)] = syntacticTextDocuments.map { (id: Int($0.id), score: -$0.rank ) }
            
            rankedDocumentIDs = try RelativeScoreFusion.rank(inputs: [
                syntacticDocumentPieceInput,
                semanticSearchInput,
                documentSearchInput
            ], weights: [1/3, 1/3, 1/3])
        case .reciprocalRankedFusion:
            // Take just the document ids from the searched document pieces.
            let syntacticDocumentPieceIds = syntacticDocumentsWithBestScore.sortedByValueThenKey().map(\.key)
            
            // Take just ordered IDs from the semantic search results.
            let semanticTextIds = semanticDocumentsWithBestScore.sortedByValueThenKey().map(\.key)
            
            let documentSearchInput = syntacticTextDocuments.reduce(into: [Int: Double]()) { partialResult, doc in
                partialResult[Int(doc.id)] = -doc.rank
            }.sortedByValueThenKey().map(\.key)
            
            rankedDocumentIDs = ReciprocalRankedFusion.rank(inputs: [
                semanticTextIds,
                syntacticDocumentPieceIds,
                documentSearchInput
            ])
        }

        return rankedDocumentIDs
    }
}
