//
//  CompactionPlan.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/19/26.
//

import Foundation

struct CompactionPlan: Sendable {
    struct Move: Sendable {
        let uuid: UUID
        let documentID: UInt64
        let sourceRange: Range<Int>
        let newRange: Range<Int>
    }
    
    var moves: [Move] = []
    var slotCount: Int
    
    init(documentRanges: [UUID: DocumentLog.DocumentRange]) {
        // This explicitly does not do any filtering of non-live entires. Document ranges comes from ``DocumentLog/ranges`` which only contains live entires.
        let orderedLogs = documentRanges
            .map { (uuid: $0.key, range: $0.value) }
            .sorted { $0.range.startSlot < $1.range.startSlot }
                
        moves.reserveCapacity(orderedLogs.count)
        
        var slotCursor = 0
        
        for log in orderedLogs {
            // Length can be zero, that is okay since some documents have no embeddings (Images at the moment). They still need to be tracked in case they need to be updated later.
            let length = log.range.endSlot - log.range.startSlot
            let newRange = slotCursor..<(slotCursor + length)
            moves.append(Move(uuid: log.uuid, documentID: log.range.id, sourceRange: log.range.range, newRange: newRange))
            slotCursor += length
        }

        slotCount = slotCursor
    }
}
