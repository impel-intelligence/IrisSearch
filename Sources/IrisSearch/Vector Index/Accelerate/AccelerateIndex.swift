//
//  AcceleratIndex.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation
import IrisCommon
import Accelerate

enum AccelerateIndexError: Error, Equatable {
    case mismatchedDimensions(found: Int, expected: Int)
    case embeddingIdLengthMismatch(embeddings: Int, ids: Int)
}

final class AccelerateIndex: VectorIndex {
    private var embeddingProvider: EmbeddingProvider
    private var indexLocation: URL

    private var generation: DatabaseGeneration
    
    private var compactionInProgress: Bool = false
    
    var needsCompaction: Bool { generation.slotMap.deadFraction > SlotMap.acceptableDeadFraction }
        
    init(indexLocation: URL, embeddingProvider: any IrisCommon.EmbeddingProvider) throws {
        self.indexLocation = indexLocation
        self.embeddingProvider = embeddingProvider
        
        let currentGeneration = DatabaseGeneration.getCurrentDatabase(in: indexLocation)
    
        if let currentGeneration {
            generation = try DatabaseGeneration.load(generation: currentGeneration, in: indexLocation)
        } else {
            generation = try DatabaseGeneration.new(at: indexLocation, generation: 0, dimensions: UInt64(embeddingProvider.dimension))
            try DatabaseGeneration.writeCurrentDatabasePointer(for: 0, in: indexLocation)
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
        let writtenSlots = try generation.submit(embeddings: embeddings, ids: ids, documentUUID: document.uuid, documentID: UInt64(document.id ?? 0))
    }
    
    func removeDocument(documentUUID: UUID, documentID: Int64, pieceIDs: [Int]) throws {
        try generation.delete(documentUUID: documentUUID, documentID: documentID)
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
    /// Compacts the current generation into a new generation
    ///
    /// Uses `nonisolated(nonsending)` which is only safe because the only spot that leaves the actor is the `Task.detached`.  The only thing captured in that Task are local variables, which makes this data-race safe.
    ///
    /// Since deletions never remove content from `vec.bin`, the only way to reclaim space is through a compaction that occurs whenever ``AccelerateIndex/needsCompaction`` flips and a delete or update is pushed from IrisDB.
    ///
    /// Compaction is a three step process, the first is to create the compaction plan which figures out how to re-organize the live documents into a contagious array. This is done by looping over ``DocumentLog/ranges`` and inserting documents one after another. Since ``DocumentLog/ranges`` only tracks live documents, this makes sure that the new plan is only for live documents.
    /// The second step is to actually create the new database. This is done by looping over the planned moves and copying data from the existing `vec.bin` into a new `vec.bin`. This is done off the current thread, using a named ``Task/detached(name:)``.
    /// The third step is the atomic replacement of the new file. The new database is written, synchronized and then swapped with the old one. A pointer is written to tell the next launch of the index what the new generation is.
    nonisolated(nonsending) func compact() async throws {
        // We never want to run compaction more than once at the same time
        guard !compactionInProgress else { return }
        compactionInProgress = true
        defer { compactionInProgress = false }
        
        // Make sure the current generation is synced to disk
        try generation.fullSynchronize()
        
        // Create a compaction plan & initialize the compactor.
        let maxSlotSnapshot = generation.slotMap.count
        
        let plan = CompactionPlan(documentRanges: generation.documentLog.ranges)
        let slotCopy = Array(generation.slotMap[..<maxSlotSnapshot])
        
        let compactor = Compactor(
            plan: plan,
            slots: slotCopy,
            vectorFile: generation.vectorStore.url,
            destinationParent: indexLocation,
            generation: generation.generation + 1,
            dimensions: generation.vectorStore.dimensions
        )
        
        // Run the compaction on a background thread, during this the database can be mutated. Reconciling these mutations is handled in the reconcile function.
        let newGenerationNumber = try await Task.detached(name: "irisdb.index.compaction") {
            let newGeneration = try compactor.run()
            try newGeneration.fullSynchronize()
            return newGeneration.generation
        }.value
        
        // Swap out the older generation with the new one
        let next = try DatabaseGeneration.load(generation: newGenerationNumber, in: indexLocation)
        
        // Reconcile any changes that occurred on the current generation with
        try reconcile(current: generation, with: next, using: plan)
        
        // Synchronize any updates to the next generation with the file system.
        try next.synchronize()
        try DatabaseGeneration.writeCurrentDatabasePointer(for: next.generation, in: indexLocation)
        
        // Before the swap, make sure that
        try FileDurability.syncDirectory(indexLocation)
        
        let previous = generation.generation
        generation = next
        try DatabaseGeneration.delete(generation: previous, in: indexLocation)
    }

    /// Reconciles any differences between the `currentGeneration` and the `newGeneration` that occurred during compaction.
    ///
    /// The two generations are compared using the compaction `plan` created for the move.
    /// 1. If there exists a difference in the source ranges from the move and the range of the entry in the `currentGeneration` an update occurred so delete the moved data in `nextGeneration` and append the data from the `currentGeneration`.
    /// 2. If an entry does not exist in the `plan` but does exist in the `currentGeneration` an entry was appended. So append it to the `newGeneration`
    /// 3. If an entry exists in the `plan` but not in the `currentGeneration`, the entry was deleted so it needs to be deleted from the `newGeneration`
    ///
    /// - Parameters:
    ///   - currentGeneration: The current ``DatabaseGeneration`` that is considered the source of truth.
    ///   - newGeneration: The new generation that was generated from compacting the `currentGeneration`, updates are made to it.
    ///   - plan: The plan for compacting the `currentGeneration` into the `newGeneration`, used for reconciliation.
    private func reconcile(current currentGeneration: DatabaseGeneration, with newGeneration: DatabaseGeneration, using plan: CompactionPlan) throws {
        let movesByUUID = Dictionary(uniqueKeysWithValues: plan.moves.map({($0.uuid, $0)}))
        let currentRanges = currentGeneration.documentLog.ranges
        
        
        // Loop over all of the ranges currently present in the current generation.
        for (uuid, documentRange) in currentRanges {
            if let move = movesByUUID[uuid] {
                // If a range exists in both the plan and the current generation, check to see if there is a difference in slot ranges.
                guard move.sourceRange != documentRange.range else { continue }
                
                // If there is a difference, that means that the original slots went through the update path (delete, then append). To handle this, mirror that by tombstoning the move's new range and appending the new vectors to the end of the newGeneration
                try newGeneration.slotMap.tombstone(range: move.newRange)
                try copy(uuid: uuid, documentID: documentRange.id, from: documentRange.range, in: currentGeneration, onto: newGeneration)
            } else {
                // The document was appended after the plan was made, append it to the new generation.
                try copy(uuid: uuid, documentID: documentRange.id, from: documentRange.range, in: currentGeneration, onto: newGeneration)
            }
        }
        
        // Find all of the documents that exist in the plan and do not exist in the current generation. This means they were deleted and need to be deleted in the new generation.
        for (uuid, move) in movesByUUID where currentRanges[uuid] == nil {
            // Tombstone the range of slots
            try newGeneration.slotMap.tombstone(range: move.newRange)
            // Mark the document as deleted.
            try newGeneration.documentLog.append(uuid: uuid, documentID: move.documentID, slots: move.newRange, live: false)
        }
    }
    
    
    /// Copies the document (`uuid`, `documentID`) from the `currentGeneration` into the `newGeneration`.
    /// - Parameters:
    ///   - uuid: The uuid of the document to copy
    ///   - documentID: The ID of the document to copy
    ///   - sourceRange: The range that the document lived in the `currentGeneration`.
    ///   - currentGeneration: The current generation of the database.
    ///   - newGeneration: The next generation of the database, a result of compacting the `currentGeneration`.
    private func copy(uuid: UUID, documentID: UInt64, from sourceRange: Range<Int>, in currentGeneration: DatabaseGeneration, onto newGeneration: DatabaseGeneration) throws {
        let currentSlots = try currentGeneration.documentLog.range(for: uuid)
        let pieceIDs = Array(currentGeneration.slotMap[currentSlots])

        let newSlots = try newGeneration.slotMap.append(contentsOf: pieceIDs)

        // If there exists slots to append, append them
        if !sourceRange.isEmpty {
            try newGeneration.vectorStore.reserve(upTo: newSlots.upperBound)
            
            try currentGeneration.vectorStore.withVectorMatrix { matrixPointer in
                let rangeStartOffset = currentSlots.lowerBound * currentGeneration.vectorStore.dimensions
                let rangeSize = (currentSlots.count * currentGeneration.vectorStore.dimensions) * MemoryLayout<Float>.size
                let rangePointer = matrixPointer.advanced(by: rangeStartOffset)
                let vectorDataBlock = UnsafeRawBufferPointer(start: rangePointer, count: rangeSize)
                
                try newGeneration.vectorStore.write(rawVectors: Data(vectorDataBlock), at: newSlots.lowerBound)
            }
        }

        try newGeneration.documentLog.append(uuid: uuid, documentID: documentID, slots: newSlots, live: true)
    }
}
