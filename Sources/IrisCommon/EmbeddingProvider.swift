//
//  EmbeddingProvider.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

public protocol EmbeddingProvider: AnyObject, Sendable {
    var dimension: Int { get }
    
    func embed(content: String) async throws -> [Double]

    func embedQuery(content: String) async throws -> [Double]
}

public extension EmbeddingProvider {
    /// The majority of models do not need anything special for query embedding, so this passes the
    /// embedQuery function to the normal embedding function.
    func embedQuery(content: String) async throws -> [Double] {
        return try await embed(content: content)
    }
}
