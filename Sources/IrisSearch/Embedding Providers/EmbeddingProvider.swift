//
//  EmbeddingProvider.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

public protocol EmbeddingProvider: AnyObject {
    var dimension: Int { get }
    
    func embed(content: String) async throws -> [Double]
}
