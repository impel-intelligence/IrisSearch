//
//  SlotMap.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/13/26.
//

import Foundation

protocol DataExpressible {
    func encode(into bytes: inout [UInt8])
    func encoded() -> [UInt8]
}

class SlotMap: DataExpressible {
    struct SlotMapHeader: DataExpressible {
        enum Offset: UInt {
            case magic = 0
            case version = 4
            case slotCount = 8
            case generation = 16
            case flags = 24
            case crc = 28
        }
        
        static let byteCount: Int = 64
        
        func encode(into bytes: inout [UInt8]) {
            <#code#>
        }
        
        func encoded() -> [UInt8] {
            <#code#>
        }
        

    }
    
    enum Offset: UInt {
        case header = 0
        case pieceIDs = 64
    }
    
    
    static let magic = Array("IMAP".utf8)
    static let tombstoneValue: UInt64 = UInt64.max
    
    private(set) var entries: [UInt64]
    private(set) var deadCount: Int = 0
    private let generation: Int
    
    public var count: Int { entries.count }
    public var deadFraction: Double { count == 0 ? 0 : Double(deadCount) / Double(count) }
    
    var byteCount: Int {
        SlotMapHeader.byteCount + (count * MemoryLayout<UInt64>.size)
    }
    
    init(entries: [UInt64]) {
        self.entries = entries
        self.generation = 0
        scanDeadCount()
    }
    
    private func scanDeadCount() {
        deadCount = entries.count { $0 == SlotMap.tombstoneValue }
    }
    
    /// Appends the serialized record. There is no offset parameter: the destination's current end *is* the offset, so callers cannot pass an inconsistent one.
    func encode(into bytes: inout [UInt8]) {
        let base = bytes.count
        bytes.append(contentsOf: repeatElement(0, count: byteCount))
        bytes.store(magic, at: <#T##Int#>)
//        bytes.store(uuid, at: base + Offset.uuid)
//        bytes.store(UInt64(bitPattern: documentID), at: base + Offset.documentID)
//        bytes.store(UInt64(slots.lowerBound), at: base + Offset.slotStart)
//        bytes.store(UInt64(slots.upperBound), at: base + Offset.slotEnd)
//        bytes.store(sequence, at: base + Offset.sequence)
//        bytes.store(flags.rawValue, at: base + Offset.flags)
//        bytes.store(CRC32.checksum(bytes[base ..< base + Offset.checksum]), at: base + Offset.checksum)
    }

    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        encode(into: &bytes)
        return bytes
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
