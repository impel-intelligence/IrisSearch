//
//  HashEmbedder.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation
import IrisCommon

/// A deterministic feature-hashing embedder used to separate database cost from model cost.
///
/// Every real embedding provider costs milliseconds per chunk, which at PhD-scale corpus sizes
/// dominates the wall clock and hides how SQLite and FAISS actually scale. This embedder produces a
/// vector in a few microseconds, so a run using it measures the storage and retrieval layers almost
/// exclusively. The vectors carry no semantic meaning — use this to time the system, never to judge
/// result quality.
///
/// The mapping is the standard hashing trick: tokens are hashed to a bucket with FNV-1a, and a second
/// hash bit picks the sign so that vectors are not uniformly positive. Identical text always produces
/// an identical vector, which keeps runs reproducible.
///
/// - Authored by: Claude Opus 5 (Anthropic)
final class HashEmbedder: EmbeddingProvider, Sendable {
    let dimension: Int

    init(dimension: Int) {
        self.dimension = max(dimension, 8)
    }

    /// Produces the hashed bag-of-tokens vector for `content`.
    ///
    /// - Parameter content: The text to embed.
    /// - Returns: An L2-normalized vector of length ``dimension``. Text with no tokens yields a fixed
    ///            non-zero unit vector, because FAISS renormalization of an all-zero vector is undefined.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func embed(content: String) async throws -> [Double] {
        var vector = [Double](repeating: 0, count: dimension)
        var tokenCount = 0

        for token in content.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard token.count > 1 else { continue }
            let hash = HashEmbedder.fnv1a(token.lowercased())
            let bucket = Int(hash % UInt64(dimension))
            let sign: Double = (hash >> 63) == 1 ? -1 : 1
            vector[bucket] += sign
            tokenCount += 1
        }

        guard tokenCount > 0 else {
            var fallback = [Double](repeating: 0, count: dimension)
            fallback[0] = 1
            return fallback
        }

        // Normalize so distances land in the same range a real provider would produce.
        let magnitude = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0 else {
            var fallback = [Double](repeating: 0, count: dimension)
            fallback[0] = 1
            return fallback
        }

        for index in vector.indices { vector[index] /= magnitude }
        return vector
    }

    /// FNV-1a over the UTF-8 bytes of `string`.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
