//
//  StorageProtocol.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import Foundation

protocol VectorStorage: AnyObject {
    var embeddingProvider: EmbeddingProvider { get }
    var dimension: Int { get }
    
    func addDocument(id: UUID, content: String) async throws
    func addDocument(id: UUID, embeddings: [Float], content: String) async throws

    func deleteDocument(id: UUID)
}

