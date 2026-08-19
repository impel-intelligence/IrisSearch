//
//  AcceleratIndex.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation
import IrisCommon
import Accelerate

enum AccelerateIndexError: Error {
    case mismatchedDimensions(found: Int, expected: Int)
    case embeddingIdLengthMismatch(embeddings: Int, ids: Int)
}

final class AccelerateIndex: VectorIndex {
    private var embeddingProvider: EmbeddingProvider
    private var indexLocation: URL
    
    private var generation: DatabaseGeneration
    
    private var compactionInProgress: Bool = false
    
    init(indexLocation: URL, embeddingProvider: any IrisCommon.EmbeddingProvider) throws {
        self.indexLocation = indexLocation
        self.embeddingProvider = embeddingProvider
        
        let currentGeneration = try DatabaseGeneration.detect(in: indexLocation)
    
        if let currentGeneration {
            generation = try DatabaseGeneration.load(generation: currentGeneration, in: indexLocation)
        } else {
            generation = try DatabaseGeneration.new(at: indexLocation, generation: 0, dimensions: UInt64(embeddingProvider.dimension))
        }
        
        guard generation.vectorStore.dimensions == embeddingProvider.dimension else {
            throw AccelerateIndexError.mismatchedDimensions(found: generation.vectorStore.dimensions, expected: embeddingProvider.dimension)
        }
    }
}

// MARK: Document Management
extension AccelerateIndex {
    func addDocument(document: IrisDocument) throws {
        var embeddings: [[Float]] = []
        var ids: [UInt64] = []
        
        // For each embedding in the document, add it with the pieces's rowID as its ID
        // TODO: Remove empty embeddings dodge. It is here because images are not currently embedded.
        for piece in document.pieces where !piece.embeddings.isEmpty {
            guard let pieceID = piece.id else { continue }
            
            // Make sure that the dimensions for this vector are correct.
            guard piece.embeddings.count == self.embeddingProvider.dimension else {
                throw AccelerateIndexError.mismatchedDimensions(found: piece.embeddings.count, expected: generation.vectorStore.dimensions)
            }
            
            let normalized = l2Normalize(vector: piece.embeddings)
            embeddings.append(normalized)
            ids.append(UInt64(pieceID))
        }
        
        // Write the IDs to the database
        guard embeddings.count == ids.count else {
            throw AccelerateIndexError.embeddingIdLengthMismatch(embeddings: embeddings.count, ids: ids.count)
        }
        
        // Writes the submission to the database stores.
        try generation.submit(embeddings: embeddings, ids: ids, documentUUID: document.uuid, documentID: UInt64(document.id ?? 0))
    }
    
    func removeDocument(documentUUID: UUID, documentID: Int64, pieceIDs: [Int]) throws {
        try generation.delete(documentUUID: documentUUID, documentID: documentID, pieceIDs: pieceIDs)
    }
}

// MARK: Search
extension AccelerateIndex {
    func search(query: [Float], kItems k: Int) throws -> [(id: Int, distance: Float)] {
        // Search over the entire index.
        return try search(query: query, kItems: k, slots: 0..<generation.slotMap.count)
    }
    
    func search(query: [Float], kItems k: Int, collection: UUID) throws -> [(id: Int, distance: Float)] {
        // TODO: Populate
        let searchRange = try generation.documentLog.range(for: collection)
        return try search(query: query, kItems: k, slots: searchRange)
    }
    
    /// Search across a range of slots and return the top `k` items.
    ///  
    /// - Parameters:
    ///   - query: <#query description#>
    ///   - k: <#k description#>
    ///   - slots: <#slots description#>
    /// - Returns: <#description#>
    private func search(query: [Float], kItems k: Int, slots: Range<Int>) throws -> [(id: Int, distance: Float)] {
        guard k > 0, !slots.isEmpty else { return [] }
        
        let dimensions = generation.vectorStore.dimensions
        guard query.count == dimensions else {
            throw AccelerateIndexError.mismatchedDimensions(found: query.count, expected: dimensions)
        }
        
        let slotMap = generation.slotMap
        let normalizedQuery = l2Normalize(vector: query)
        
        var distances: [Float] = [Float](repeating: 0, count: slots.count)
        
        try generation.vectorStore.withVectorMatrix { startingMatrixBase in
            let matrixBase = startingMatrixBase.advanced(by: slots.lowerBound * dimensions)
            
            distances.withUnsafeMutableBufferPointer { distanceBuffer in
                normalizedQuery.withUnsafeBufferPointer { queryBuffer in
                    let distanceBase = distanceBuffer.baseAddress!
                    let queryBase = queryBuffer.baseAddress!
                    
                    vDSP_mmul(matrixBase, 1, queryBase, 1, distanceBase, 1, vDSP_Length(slots.count), 1, vDSP_Length(dimensions))
                }
            }
        }
        
        let resultStack = TopKStack(capacity: k)

        // Take the TopK distances and their slot as the result.
        for index in distances.indices {
            let slot = slots.startIndex + index
            // Skip any vectors that are marked as dead
            guard slotMap.isLive(slot) else { continue }
            
            let distance = distances[index]
            resultStack.insert(slot: slot, distance: distance)
        }
        
        return resultStack.descending().map { (id: Int(slotMap[$0.slot]), distance: $0.distance) }
    }
}

extension AccelerateIndex {
    /// l2 normalize a vector, if it is already normalized return the normal vector.
    /// - Parameter vector: The vector to normalize.
    /// - Returns: An l2 normalized vector, if already normalized the original vector.
    func l2Normalize(vector: [Float]) -> [Float] {
        // Calculate the sum of the the square of each dimension in the vector.
        let squareSum: Float = vector.reduce(0.0) { partialResult, float in
            partialResult + (float * float)
        }
        
        // TODO: Use accelerate for sqrt
        let norm = sqrt(squareSum)
        
        // The vector is already normalized so just return it
        guard norm != 0 else { return vector }
        
        // Make vector mutable
        var vector = vector

        // Normalize each dimension of the vector
        for index in 0..<vector.count {
            vector[index] /= norm
        }

        return vector
    }
}

// MARK: Compaction
extension AccelerateIndex {
    func compact() throws {
        // We never want to run compaction more than once at the same time
        guard !compactionInProgress else { return }
        compactionInProgress = true
        defer { compactionInProgress = false }
        
        // Make sure the current generation is synced to disk
        try generation.synchronize()
        
        
    }
}
