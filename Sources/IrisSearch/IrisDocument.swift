//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import GRDB
import IrisCommon
import Foundation

//public struct IrisDocument: Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
//    public struct Piece: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
//        public var id: Int64? = nil
//        public let pieceIndex: Int
//        public let content: EmbeddableContent
//        public let embeddings: [[Float]]
//        
//        init(pieceIndex: Int, content: EmbeddableContent, embeddings: [[Float]]) {
//            self.pieceIndex = pieceIndex
//            self.content = content
//            self.embeddings = embeddings
//        }
//        
//        public mutating func didInsert(_ inserted: InsertionSuccess) {
//            self.id = inserted.rowID
//        }
//    }
//    
//    public static let databaseTableName: String = "documents"
//    
//    nonisolated(unsafe) public var id: Int64? = nil
//    public let uuid: UUID
//    public let pieces: [Piece]
//    
//    public init(uuid: UUID, contentPieces: [Piece], embeddings: [[Float]]) {
//        self.uuid = uuid
//        self.pieces = contentPieces
//    }
//    
//    public init(row: GRDB.Row) throws {
//        id = row["id"]
//        uuid = row["uuid"]
//        pieces = []
//    }
//    
//    public func encode(to container: inout GRDB.PersistenceContainer) throws {
//        container["id"] = id
//        container["uuid"] = uuid
//    }
//    
//    public mutating func didInsert(_ inserted: InsertionSuccess) {
//        id = inserted.rowID
//    }
//}
//

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
