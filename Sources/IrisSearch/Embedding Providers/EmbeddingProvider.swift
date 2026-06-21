//
//  EmbeddingProvider.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

public protocol EmbeddingProvider: AnyObject, Sendable {
    var dimension: Int { get }
        
    init() throws

    func embed(content: String) async throws -> [Double]
}
