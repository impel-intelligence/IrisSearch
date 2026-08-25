//
//  Compactor.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/19/26.
//

import Foundation

struct Compactor: Sendable {
    enum CompactorError: Error {
        case couldNotGetBaseAddress
    }
    
    let plan: CompactionPlan
    
    // Local copies of piece IDs in their slots.
    let slots: [UInt64]
    let vectorFile: URL
    let destinationParent: URL
    let generation: UInt64
    let dimensions: Int
    var faultInjector: FaultInjector? = nil
    
    func run() throws -> DatabaseGeneration {
        // If the plan is empty everything was deleted, so just set the new slots to 0
        let newMaximumSlots = plan.moves.map( { $0.newRange.upperBound }).max() ?? 0
        
        let newGeneration = try DatabaseGeneration.new(at: destinationParent, generation: generation, dimensions: UInt64(dimensions))
        
        try newGeneration.vectorStore.reserve(upTo: newMaximumSlots)
        
        try faultInjector?(.compactorAfterReserve)
        
        let vectorSource = try Data(contentsOf: vectorFile, options: .alwaysMapped)
        
        try vectorSource.withUnsafeBytes { vectorBuffer in
            guard let base = vectorBuffer.baseAddress?.advanced(by: VectorStoreFile.Header.byteCount).assumingMemoryBound(to: Float.self) else {
                throw CompactorError.couldNotGetBaseAddress
            }
            
            for move in plan.moves {
                let ids = Array(slots[move.sourceRange])
                let newRange = try newGeneration.slotMap.append(contentsOf: ids)
                try faultInjector?(.compactorAfterMapWrite)

                // If the range is empty there are no vectors to move, but the document still needs to be marked as live so add an entry into the document log.
                guard !newRange.isEmpty else {
                    try newGeneration.documentLog.append(uuid: move.uuid, documentID: move.documentID, slots: move.newRange, live: true)
                    try faultInjector?(.compactorAfterRecordAppend)
                    continue
                }
                
                let rangeStartOffset = move.sourceRange.lowerBound * dimensions
                let rangeSize = (move.sourceRange.count * dimensions) * MemoryLayout<Float>.size
                let rangePointer = base.advanced(by: rangeStartOffset)
                let vectorDataBlock = UnsafeRawBufferPointer(start: rangePointer, count: rangeSize)
                
                try newGeneration.vectorStore.write(rawVectors: Data(vectorDataBlock), at: newRange.lowerBound)
                
                try faultInjector?(.compactorAfterVectorWrite)
                
                try newGeneration.documentLog.append(uuid: move.uuid, documentID: move.documentID, slots: newRange, live: true)
                
                try faultInjector?(.compactorAfterRecordAppend)
            }
        }
        
        return newGeneration
    }
}
