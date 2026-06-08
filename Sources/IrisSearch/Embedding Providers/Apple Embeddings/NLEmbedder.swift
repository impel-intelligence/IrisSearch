//
//  NLEmbedder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import NaturalLanguage

extension IrisLanguage {
    var nlLanguage: NLLanguage {
        switch self {
        case .english:
            return .english
        }
    }
}

class NLEmbedder: EmbeddingProvider {
    enum EmbeddingError: Error {
        case couldNotCreateVector
        case languageUnavailable(NLLanguage)
    }
    
    private var embedding: NLEmbedding
        
    var dimension: Int {
        return embedding.dimension
    }
    
    init(language: IrisLanguage) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language.nlLanguage) else {
            throw EmbeddingError.languageUnavailable(language.nlLanguage)
        }
        
        self.embedding = embedding
    }
    
    func embed(content: String) async throws -> [Double] {
        guard let embedding = embedding.vector(for: content) else {
            throw EmbeddingError.couldNotCreateVector
        }
        
        return embedding
    }
}
