//
//  NLContextualEmbedder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import NaturalLanguage

public class NLContextualEmbedder: EmbeddingProvider {
    enum EmbeddingError: Error {
        case couldNotCreateVector
        case languageUnavailable(NLLanguage)
    }
    
    private var embedding: NLContextualEmbedding
    private var language: NLLanguage
    
    public var dimension: Int {
        return embedding.dimension
    }
    
    required public convenience init() throws {
        try self.init(language: .english)
    }

    public init(language: IrisLanguage) throws {
        self.language = language.nlLanguage
        guard let _embedding = NLContextualEmbedding(language: self.language) else {
            throw EmbeddingError.languageUnavailable(self.language)
        }
        
        self.embedding = _embedding
        try self.embedding.load()
    }
    
    public func embed(content: String) async throws -> [Double] {
        let embedding = try embedding.embeddingResult(for: content, language: language)
        #warning("Finish this")
        return []
    }
}
