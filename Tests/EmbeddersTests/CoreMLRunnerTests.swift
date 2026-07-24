//
//  CoreMLRunnerTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import Foundation
import Testing
@testable import Embedders
import IrisCommon

@Suite("CoreML Embedder Tests")
struct CoreMLRunnerTests {
    // BGE-small-en-v1.5's actual CLS-pooled embedding size. This is an independent
    // ground truth, not read from config.json -- see `configuredDimensionMatchesRealOutput`,
    // which specifically checks whether config.json's `dimensions` field agrees with it.
    static let expectedDimension = 384

    private func makeEmbedder() throws -> CoreMLEmbedder {
        let modelDirectory = try #require(Bundle.module.url(forResource: "bge", withExtension: nil, subdirectory: "ml"))
        return try CoreMLEmbedder(modelDirectory: modelDirectory)
    }

    @Test("Model and tokenizer load without throwing")
    func modelLoads() throws {
        _ = try makeEmbedder()
    }

    @Test("embed(content:) returns BGE-small's actual 384-dim output")
    func embeddingHasExpectedDimension() throws {
        let embedder = try makeEmbedder()
        let embedding = try embedder.embed(content: "Hello world!")
        #expect(embedding.count == Self.expectedDimension)
    }

    @Test("embedder.dimension (from config.json) agrees with the real output size")
    func configuredDimensionMatchesRealOutput() throws {
        let embedder = try makeEmbedder()
        let embedding = try embedder.embed(content: "Hello world!")
        #expect(embedder.dimension == embedding.count)
    }

    @Test("Output is L2-normalized, since the model normalizes internally")
    func embeddingIsUnitNorm() throws {
        let embedder = try makeEmbedder()
        let embedding = try embedder.embed(content: "Hello world!")
        let norm = (embedding.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(norm - 1.0) < 0.01)
    }

    @Test("Output contains no NaN/Inf")
    func embeddingContainsNoNaNOrInfinite() throws {
        // A garbled attention_mask (e.g. raw token IDs used in place of 0/1 flags)
        // corrupts the softmax badly enough to typically surface as NaN/Inf here --
        // this is the cheapest possible check for that whole class of bug.
        let embedder = try makeEmbedder()
        let embedding = try embedder.embed(content: "Hello world!")
        #expect(embedding.allSatisfy { $0.isFinite })
    }

    @Test("Same input produces identical output across calls")
    func embeddingIsDeterministic() throws {
        let embedder = try makeEmbedder()
        let first = try embedder.embed(content: "Hello world!")
        let second = try embedder.embed(content: "Hello world!")
        #expect(first == second)
    }

    @Test("Different inputs produce different embeddings")
    func differentTextProducesDifferentEmbeddings() throws {
        let embedder = try makeEmbedder()
        let a = try embedder.embed(content: "The cat sat on the mat.")
        let b = try embedder.embed(content: "Quantum mechanics describes subatomic particles.")
        #expect(a != b)
    }

    @Test("embedQuery prepends the search prefix, producing a different vector than embed for the same text")
    func embedQueryDiffersFromEmbed() async throws {
        let embedder = try makeEmbedder()
        let text = "What is the capital of France?"
        let passageVector = try embedder.embed(content: text)
        let queryVector = try await embedder.embedQuery(content: text)
        #expect(passageVector != queryVector)
    }

    @Test("Longer, more numerically-varied input still embeds to a finite, unit-norm vector")
    func longerInputStillProducesValidEmbedding() throws {
        // Regression guard for attention_mask being conflated with input_ids: if the
        // "mask" values were accidentally raw token IDs instead of 0/1 flags, longer
        // inputs with more/larger token IDs are the most likely to blow the softmax
        // up into NaN/Inf, so this specifically exercises a longer input rather than
        // relying only on the short strings used above.
        let embedder = try makeEmbedder()
        let longText = """
            The quick brown fox jumps over the lazy dog, while researchers in the \
            field of computational linguistics continue to study how large language \
            models represent semantic meaning across many different domains and languages.
            """
        let embedding = try embedder.embed(content: longText)
        #expect(embedding.count == Self.expectedDimension)
        #expect(embedding.allSatisfy { $0.isFinite })
        let norm = (embedding.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(norm - 1.0) < 0.01)
    }
}
