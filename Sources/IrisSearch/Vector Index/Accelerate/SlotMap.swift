//
//  SlotMap.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/13/26.
//

import Foundation

class SlotMap {
    static let magic = Array("IMAP".utf8)
    static let tombstoneValue: UInt64 = UInt64.max
    
    private(set) var entries: [UInt64]
    private(set) var deadCount: Int
    
    public var count: Int { entries.count }
    public var deadFraction: Double { count == 0 ? 0 : Double(deadCount) / Double(count) }
    
    init(entries: [UInt64], deadCount: Int) {
        self.entries = entries
        self.deadCount = deadCount
    }
    
    
}

extension SlotMap {
    subscript(slot: Int) -> UInt64 {
        return entries[slot]
    }
    
    /// Append contents of a [UInt64] array
    /// - Parameter contentsOf: The array of pieceIDs to append to the map file.
    /// - Returns: The index range where the contents were added.
    func append(contentsOf array: [UInt64]) -> Range<Int> {
        let startRange = entries.count
        entries.append(contentsOf: array)
        
        return startRange..<(startRange + array.count)
    }
    
    func tombstone(range: Range<Int>) {
        guard range.lowerBound >= 0 && range.upperBound <= count else { return }
        var newlyDead = 0
        for slot in range where entries[slot] != SlotMap.tombstoneValue { newlyDead += 1 }
        deadCount += newlyDead
        entries.replaceSubrange(range, with: Array(repeating: SlotMap.tombstoneValue, count: range.count))
    }
    
    func isLive(_ slot: Int) -> Bool {
        return entries[slot] != SlotMap.tombstoneValue
    }
}
