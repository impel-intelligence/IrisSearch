//
//  NLEmbedder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import NaturalLanguage
import Synchronization
import IrisCommon

extension IrisLanguage {
    var nlLanguage: NLLanguage {
        switch self {
        case .english:
            return .english
        }
    }
}

@available(macOS 15.0, *)
public final class NLEmbedder: EmbeddingProvider, Sendable {
    public enum EmbeddingError: Error {
        case couldNotCreateVector
        case languageUnavailable(NLLanguage)
    }
    
    private let embeddingMutex: Mutex<NLEmbedding>
    public let dimension: Int
    
    required public convenience init() throws {
        try self.init(language: .english)
    }
    
    public init(language: IrisLanguage) throws {
        guard let _embedding = NLEmbedding.sentenceEmbedding(for: language.nlLanguage) else {
            throw EmbeddingError.languageUnavailable(language.nlLanguage)
        }
        dimension = _embedding.dimension
        embeddingMutex = Mutex(_embedding)
    }
    
    public func embed(content: String) async throws -> [Double] {
        try embeddingMutex.withLock { embedding in
            guard let embedding = embedding.vector(for: content) else {
                throw EmbeddingError.couldNotCreateVector
            }
            
            return embedding
        }
    }
}
