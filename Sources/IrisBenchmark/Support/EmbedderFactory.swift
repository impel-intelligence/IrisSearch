//
//  EmbedderFactory.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import AppleIntelligenceEmbedder
import CoreMLEmbedder
import Foundation
import IrisCommon

enum EmbedderFactoryError: Error, CustomStringConvertible {
    case missingCoreMLModelDirectory

    var description: String {
        switch self {
        case .missingCoreMLModelDirectory:
            return "--embedder coreml requires --coreml-model <path to a directory containing a .mlmodelc, vocab.txt and config>."
        }
    }
}

/// Builds the embedding provider named by the benchmark options.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum EmbedderFactory {
    /// Creates the configured provider along with a human readable label for the report.
    ///
    /// - Parameter options: The parsed benchmark options.
    /// - Returns: The provider and the name to record in the results.
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func makeEmbedder(options: BenchmarkOptions) throws -> (provider: any EmbeddingProvider, label: String) {
        switch options.embedderKind {
        case .naturalLanguage:
            let embedder = try NLEmbedder(language: .english)
            return (embedder, "NLEmbedder (NaturalLanguage sentence embedding, d=\(embedder.dimension))")
        case .contextual:
            let embedder = try NLContextualEmbedder(language: .english)
            return (embedder, "NLContextualEmbedder (NaturalLanguage contextual embedding, d=\(embedder.dimension))")
        case .coreml:
            guard let directory = options.coreMLModelDirectory else {
                throw EmbedderFactoryError.missingCoreMLModelDirectory
            }
            let embedder = try CoreMLEmbedder(modelDirectory: directory)
            return (embedder, "CoreMLEmbedder (\(directory.lastPathComponent), d=\(embedder.dimension))")
        case .hash:
            let embedder = HashEmbedder(dimension: options.hashDimension)
            return (embedder, "HashEmbedder (feature hashing, d=\(embedder.dimension), no semantics)")
        }
    }
}
