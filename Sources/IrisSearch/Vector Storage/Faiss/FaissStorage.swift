//
//  FaissStorage.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import Foundation
import System
import SwiftFaiss
import SwiftFaissC


class FaissStorage: VectorStorage {
    
    private(set) var dimension: Int = 0
    private(set) var embeddingProvider: EmbeddingProvider
    var databaseURL: URL

    init(provider: EmbeddingProvider, databaseLocation: URL, databaseName: String = "main") throws {
        embeddingProvider = provider
        databaseURL = databaseLocation.appending(path: "\(databaseName).idb")
        
        if !FileManager.default.fileExists(atPath: databaseLocation.path()) {
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        }
    }
    
    func addDocument(id: UUID, embeddings: [Float], content: String) async throws {
        
    }

    func addDocument(id: UUID, content: String) async throws {
        var embedding: [Float] = try await embeddingProvider.embed(content: content).compactMap { value in
            return Float(value)
        }
        
        // Normalize the embedding.
        faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &embedding)
        
//        let index = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
//        try index.train(results.vectors)
//        try index.add(results.vectors)
    }
    
    func deleteDocument(id: UUID) {
        
    }
}
