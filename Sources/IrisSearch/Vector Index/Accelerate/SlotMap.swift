//
//  SlotMap.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/13/26.
//

import Foundation
import CryptoSwift
import System

enum SlotMapError: Error {
    case notASlotMap
    case truncatedFile(found: Int, needed: Int)
    case unsupportedVersion(found: UInt32, supported: UInt32)
    case checksumMismatch(found: UInt32, expected: UInt32)
    case slotCountExceedsFileSize(declaredSlots: Int, maximumSlots: Int)
}

class SlotMap: DataExpressible {
    struct Header: DataExpressible {
        enum Offset: Int {
            case magic = 0
            case version = 4
            case slotCount = 8
            case generation = 16
            case flags = 24
            case checksum = 28
        }
        
        struct Flags: OptionSet {
            let rawValue: UInt8
            
            static let cleanShutdown = Flags(rawValue: 1 << 0)
            
            static let empty: Flags = []
        }

        static let magic = Array("IMAP".utf8)
        static let byteCount: Int = 64
        static let version: UInt32 = 1
        
        var slotCount: Int
        var generation: UInt64
        var flags: Flags
        
        public init(slotCount: Int, generation: UInt64, flags: Flags) {
            self.slotCount = slotCount
            self.generation = generation
            self.flags = flags
        }

        public init(bytes: [UInt8], fileLength: Int) throws {
            // Make sure we have at least the minimum amount of bytes needed for the header.
            guard bytes.count >= Self.byteCount else {
                throw SlotMapError.truncatedFile(found: bytes.count, needed: Self.byteCount)
            }
            
            let base = bytes.startIndex
            
            let magic = Array(bytes[base..<base + Self.magic.count])
            guard magic == Self.magic else {
                throw SlotMapError.notASlotMap
            }
            
            let version: UInt32 = bytes.load(at: base + Offset.version.rawValue)
            guard version == Self.version else {
                throw SlotMapError.unsupportedVersion(found: version, supported: Self.version)
            }
            
            let storedCRC: UInt32 = bytes.load(at: base + Offset.checksum.rawValue)
            let computedCRC: UInt32 = Checksum.crc32(Array(bytes[base..<base + Offset.checksum.rawValue]))
            guard storedCRC == computedCRC else {
                throw SlotMapError.checksumMismatch(found: storedCRC, expected: computedCRC)
            }
            
            let claimedSlotCount: Int = bytes.load(at: base + Offset.slotCount.rawValue)
            let slotCapacity = max(0, fileLength - Self.byteCount) / MemoryLayout<UInt64>.size
            guard claimedSlotCount <= slotCapacity else {
                throw SlotMapError.slotCountExceedsFileSize(declaredSlots: claimedSlotCount, maximumSlots: slotCapacity)
            }
            
            self.slotCount = claimedSlotCount
            self.generation = bytes.load(at: base + Offset.generation.rawValue)
            self.flags = Flags(rawValue: bytes.load(at: base + Offset.flags.rawValue))
        }

        func encode(into bytes: inout [UInt8]) {
            let base = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: Self.byteCount))
            bytes.replaceSubrange(base ..< base + Self.magic.count, with: Self.magic)
            bytes.store(SlotMap.Header.version, at: base + Offset.version.rawValue)
            bytes.store(slotCount, at: base + Offset.slotCount.rawValue)
            bytes.store(generation, at: base + Offset.generation.rawValue)
            bytes.store(flags.rawValue, at: base + Offset.flags.rawValue)
            
            // Take a checksum of the first 28 bytes and store it.
            let checksum = Checksum.crc32(Array(bytes[base ..< base + Offset.checksum.rawValue]))
            bytes.store(checksum, at: base + Offset.checksum.rawValue)
        }
        
        func encoded() -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Self.byteCount)
            encode(into: &bytes)
            return bytes
        }
    }
    
    enum Offset: Int {
        case header = 0
        case pieceIDs = 64
    }

    static let magic = Array("IMAP".utf8)
    static let tombstoneValue: UInt64 = UInt64.max
    
    private(set) var entries: [UInt64]
    private(set) var deadCount: Int = 0
    
    private(set) var header: SlotMap.Header
    
    public var count: Int { entries.count }
    public var deadFraction: Double { count == 0 ? 0 : Double(deadCount) / Double(count) }
    
    var byteCount: Int {
        SlotMap.Header.byteCount + (count * MemoryLayout<UInt64>.size)
    }
    
    init(entries: [UInt64]) {
        self.entries = entries
        self.header = Header(slotCount: entries.count, generation: 0, flags: .empty)
        scanDeadCount()
    }
    
    init(bytes: [UInt8], fileSize: Int) throws {
        precondition(SlotMap.Header.byteCount % MemoryLayout<UInt64>.alignment == 0, "Entries must start aligned for bindMemory")
        header = try SlotMap.Header(bytes: bytes, fileLength: fileSize)
        let expectedSlotEnd = Offset.pieceIDs.rawValue + (header.slotCount * MemoryLayout<UInt64>.size)
        
        guard expectedSlotEnd > Offset.pieceIDs.rawValue else {
            entries = []
            return
        }
        
        // Remap the rest of the bytes into a little endian UInt64 array.
        entries = bytes.withUnsafeBytes { raw in
            let buffer = UnsafeRawBufferPointer(rebasing: raw[Offset.pieceIDs.rawValue..<expectedSlotEnd])
            let array = Array(buffer.bindMemory(to: UInt64.self))
            return array.map { UInt64(littleEndian: $0) }
        }
        
        scanDeadCount()
    }
    
    private func scanDeadCount() {
        deadCount = entries.count { $0 == SlotMap.tombstoneValue }
    }
    
    /// Appends the serialized record. There is no offset parameter: the destination's current end *is* the offset, so callers cannot pass an inconsistent one.
    func encode(into bytes: inout [UInt8]) {
        header.encode(into: &bytes)
        // Do NOT use keypath here, it slows the code down by 45x
        entries.map { $0.littleEndian }.withUnsafeBytes { bytes.append(contentsOf: $0) }
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
    @discardableResult
    func append(contentsOf array: [UInt64]) -> Range<Int> {
        let startRange = entries.count
        entries.append(contentsOf: array)
        header.slotCount = Int(entries.count)
        
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
