//
//  NLContextualEmbedder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import NaturalLanguage
import os
import Synchronization
import IrisCommon

public final class NLContextualEmbedder: TextEmbeddingProvider, Sendable {
    enum EmbeddingError: Error {
        case couldNotCreateVector
        case languageUnavailable(NLLanguage)
    }

    private let embeddingMutex: Mutex<NLContextualEmbedding>
    private let language: NLLanguage
    public let dimension: Int
    
    required public convenience init() throws {
        try self.init(language: .english)
    }

    public init(language: IrisLanguage) throws {
        self.language = language.nlLanguage
        guard let _embedding = NLContextualEmbedding(language: self.language) else {
            throw EmbeddingError.languageUnavailable(self.language)
        }
        
        try _embedding.load()
        
        dimension = _embedding.dimension
        embeddingMutex = Mutex(_embedding)
    }
    
    public func embed(content: String) async throws -> [Double] {
        // Serialize access: the underlying model is not safe to call concurrently.
        try embeddingMutex.withLock { embedding in
            let result = try embedding.embeddingResult(for: content, language: language)
            
            var tokenCount: Int = 0
            var pooledVector: [Double] = Array(repeating: 0.0, count: embedding.dimension)
     
            // Create a pooled vector that adds up each dimension of every returned vector.
            result.enumerateTokenVectors(in: content.startIndex..<content.endIndex) { vector, _ in
                for index in 0..<embedding.dimension {
                    pooledVector[index] += vector[index]
                }
                
                tokenCount += 1
                return true
            }
            
            // Protect against divide-by-zero errors
            guard tokenCount > 0 else { return Array(repeating: 0.0, count: embedding.dimension) }
            
            // Divide all of the dimensions by the
            for i in 0..<embedding.dimension {
                pooledVector[i] /= Double(tokenCount)
            }
            
            return pooledVector
        }
    }
}
