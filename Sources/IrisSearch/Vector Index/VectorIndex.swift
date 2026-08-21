//
//  VectorIndex.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/12/26.
//

import Foundation
import IrisCommon

public protocol VectorIndex {
    init(indexLocation: URL, embeddingProvider: EmbeddingProvider) throws
    
    func addDocument(document: IrisDocument) throws
    func removeDocument(documentUUID: UUID, documentID: Int64, pieceIDs: [Int]) throws
    
    func search(query: [Float], kItems k: Int) throws -> [(id: Int, distance: Float)]
    func search(query: [Float], kItems k: Int, collection: UUID) throws -> [(id: Int, distance: Float)]
}
