//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import GRDB
import IrisCommon
import Foundation

public struct IrisDocument: Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName: String = "documents"
    static let pieces = hasMany(DocumentPiece.self)

    nonisolated(unsafe) public var id: Int64? = nil
    public let uuid: UUID
    
    /// Loaded separately from the `document_pieces` table; not a column on `documents`.
    public var pieces: [DocumentPiece]

    public init(uuid: UUID, pieces: [DocumentPiece] = []) {
        self.uuid = uuid
        self.pieces = pieces
    }

    public init(row: GRDB.Row) throws {
        id = row["id"]
        uuid = row["uuid"]
        pieces = []
    }

    public func encode(to container: inout GRDB.PersistenceContainer) throws {
        container["id"] = id
        container["uuid"] = uuid
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}


/// A structure to match the document piece full text table used in FTS SQL searches.
struct SearchableDocumentPiece: Codable, FetchableRecord, TableRecord {
    public static let databaseTableName = "document_pieces_ft"
    
    public var id: Int64
    public var textContent: String
    public var parentID: Int64
    public var rank: Int64 // The FTS5 hidden rank column
}

/// A piece of a greater `IrisDocument`.
///
/// These pieces are constructed based on content chunks provided by `Digesters` or by either a ``TextChunker`` or ``ImageChunker``.
public struct DocumentPiece: Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    /// The SQL columns that piece data is actually saved into.
    public enum Columns {
        static let id = Column("id")
        static let contentType = Column("contentType")
        static let textContent = Column("textContent")
        static let dataContent = Column("dataContent")
        static let embeddings = Column("embeddings")
        static let parentID = Column("parentID")
    }
    
    enum PieceLoadingError: Error {
        case noData
        case noText
        case noValidContent
    }
    
    public static let databaseTableName = "document_pieces"
    
    /// The many-to-one relationship between ``DocumentPiece`` and ``IrisDocument``
    static let parent = belongsTo(IrisDocument.self)
    
    /// An SQL unique row identifier for this document piece.
    public var id: Int64? = nil
    /// The content that this piece contains. Will be split into the columns `textContent` and `dataContent` when saved into the SQL database.
    public let content: EmbeddableContent
    /// The semantic embedding for the ``EmbeddableContent``.
    public let embeddings: [Float]
    /// The ID of the parent ``IrisDocument`` that this piece belongs to.
    public var parentID: Int64?
    
    /// Create a Document Piece that has not been inserted into a GRDB database yet.
    /// - Parameters:
    ///   - content: The ``EmbeddableContent`` that this piece represents.
    ///   - embeddings: An embedding that represents the semantic content of the `content`.
    ///   - parentID: The id for the parent ``IrisDocument``
    public init(content: EmbeddableContent, embeddings: [Float], parentID: Int64? = nil) {
        self.content = content
        self.embeddings = embeddings
        self.parentID = parentID
    }
    
    public init(row: GRDB.Row) throws {
        id = row[Columns.id]
        
        let contentType: Int = row[Columns.contentType]
        
        let textContent: String? = row[Columns.textContent]
        let dataContent: Data? = row[Columns.dataContent]
        
        switch EmbeddableContent.ContentType(rawValue: contentType) {
        case .text:
            guard let textContent else { throw PieceLoadingError.noText }
            self.content = .text(content: textContent)
        case .image:
            guard let dataContent else { throw PieceLoadingError.noData }
            self.content = .image(content: dataContent, caption: textContent)
        case .none:
            throw PieceLoadingError.noValidContent
        }
        
        let embeddingsData: Data = row[Columns.embeddings]
        
        embeddings = embeddingsData.withUnsafeBytes { ptr in
            return Array(ptr.bindMemory(to: Float.self))
        }
        
        parentID = row[Columns.parentID]
    }
    
    public func encode(to container: inout GRDB.PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.contentType] = content.contentType.rawValue
        
        switch content {
        case .text(let content):
            container[Columns.textContent] = content
            container[Columns.dataContent] = nil
        case .image(let content, let caption):
            container[Columns.dataContent] = content
            container[Columns.textContent] = caption ?? nil
        }
        
        let embeddingData: Data = embeddings.withUnsafeBytes({ Data($0) })
        container[Columns.embeddings] = embeddingData
        container[Columns.parentID] = parentID
    }
    
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

extension DocumentPiece {
    public var text: String? {
        if case .text(let content) = content { return content }
        return nil
    }
}
