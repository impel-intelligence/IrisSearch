//
//  NLEmbedderTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import Testing
@testable import IrisSearch
import NaturalLanguage
import AppleIntelligenceEmbedder

@Test func simpleEmbedding() async throws {
    let embedder = try NLEmbedder(language: .english)
    
    // Generate two embeddings with the same text, this will validate that the embedding is stable
    let simpleText = "Hello World"
    let initialVector = try await embedder.embed(content: simpleText)
    let secondVector = try await embedder.embed(content: simpleText)
    
    #expect(initialVector == secondVector)
}

@Test("The embedding dimension should not be 0")
func embeddingDimension() async throws {
    let embedder = try NLEmbedder(language: .english)

    #expect(embedder.dimension != 0, "Dimensions should be a valid size.")
}

@Test("The embedding dimension should match the size of a produced vector")
func vectorSizeEqualsDimension() async throws {
    let embedder = try NLEmbedder(language: .english)

    let vector = try await embedder.embed(content: "iris")
    
    #expect(vector.count == embedder.dimension, "Vector dimensions should match embedder dimensions.")
}
