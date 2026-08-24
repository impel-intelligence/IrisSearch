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
    case tombstoneOutOfRange(range: Range<Int>, real: Range<Int>)
}

protocol WriteStrategy {
    func write(bytes: [UInt8], at offset: UInt64) throws
}

extension BinaryFile: WriteStrategy {
    func write(bytes: [UInt8], at offset: UInt64) throws {
        try self.write(data: Data(bytes), at: offset)
    }
}

/// An index map of Piece IDs to their index within the vector store.
final class SlotMap: DataExpressible {
    struct Header: DataExpressible {
        enum Offset {
            static let magic = 0
            static let version = 4
            static let slotCount = 8
            static let generation = 16
            static let checksum = 24
        }

        static let magic = Array("IMAP".utf8)
        static let byteCount: Int = 64
        static let version: UInt32 = 1
        
        let slotCount: Int
        let generation: UInt64
        
        public init(slotCount: Int, generation: UInt64) {
            self.slotCount = slotCount
            self.generation = generation
        }

        public init(bytes: [UInt8]) throws {
            // Make sure we have at least the minimum amount of bytes needed for the header.
            guard bytes.count >= Self.byteCount else {
                throw SlotMapError.truncatedFile(found: bytes.count, needed: Self.byteCount)
            }
            
            // Subscripts are absolute, so slices need `base`. `load(at:)` rebases off startIndex
            // itself, so it takes the field offset bare — adding `base` there would count
            // startIndex twice. See the note on `load(at:)` in BitWriting.swift.
            let base = bytes.startIndex

            let magic = Array(bytes[base..<base + Self.magic.count])
            guard magic == Self.magic else {
                throw SlotMapError.notASlotMap
            }

            let version: UInt32 = bytes.load(at: Offset.version)
            guard version == Self.version else {
                throw SlotMapError.unsupportedVersion(found: version, supported: Self.version)
            }

            let storedCRC: UInt32 = bytes.load(at: Offset.checksum)
            let computedCRC: UInt32 = Checksum.crc32(Array(bytes[base..<base + Offset.checksum]))
            guard storedCRC == computedCRC else {
                throw SlotMapError.checksumMismatch(found: storedCRC, expected: computedCRC)
            }

            let claimedSlotCount: Int = bytes.load(at: Offset.slotCount)
            let slotCapacity = max(0, bytes.count - Self.byteCount) / MemoryLayout<UInt64>.size
            
            guard claimedSlotCount <= slotCapacity else {
                throw SlotMapError.slotCountExceedsFileSize(declaredSlots: claimedSlotCount, maximumSlots: slotCapacity)
            }

            self.slotCount = claimedSlotCount
            self.generation = bytes.load(at: Offset.generation)
        }

        func encode(into bytes: inout [UInt8]) {
            let base = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: Self.byteCount))
            bytes.replaceSubrange(base ..< base + Self.magic.count, with: Self.magic)
            bytes.store(SlotMap.Header.version, at: base + Offset.version)
            bytes.store(slotCount, at: base + Offset.slotCount)
            bytes.store(generation, at: base + Offset.generation)
            
            // Take a checksum of the first 28 bytes and store it.
            let checksum = Checksum.crc32(Array(bytes[base ..< base + Offset.checksum]))
            bytes.store(checksum, at: base + Offset.checksum)
        }
        
        func encoded() -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Self.byteCount)
            encode(into: &bytes)
            return bytes
        }
    }
    
    enum Offset {
        static let header = 0
        static let pieceIDs = 64
    }

    static let tombstoneValue: UInt64 = UInt64.max
    static let acceptableDeadFraction: Double = 0.25
    
    private(set) var entries: [UInt64]
    private(set) var deadCount: Int = 0
    private var generation: UInt64
        
    /// A computed header that matches the most recent slot information.
    var header: SlotMap.Header {
        Header(slotCount: entries.count, generation: generation)
    }
    
    public var count: Int { entries.count }
    public var deadFraction: Double { count == 0 ? 0 : Double(deadCount) / Double(count) }
    
    var byteCount: Int {
        SlotMap.Header.byteCount + (count * MemoryLayout<UInt64>.size)
    }
    
    init(entries: [UInt64], generation: UInt64) {
        self.entries = entries
        self.generation = generation
        scanDeadCount()
    }
    
    init(bytes: [UInt8]) throws {
        precondition(SlotMap.Header.byteCount % MemoryLayout<UInt64>.alignment == 0, "Entries must start aligned for bindMemory")
        let decodedHeader = try SlotMap.Header(bytes: bytes)
        
        let expectedSlotEnd = Offset.pieceIDs + (decodedHeader.slotCount * MemoryLayout<UInt64>.size)
        
        guard expectedSlotEnd <= bytes.count else {
            throw SlotMapError.slotCountExceedsFileSize(declaredSlots: expectedSlotEnd, maximumSlots: decodedHeader.slotCount)
        }
        
        // Remap the rest of the bytes into a little endian UInt64 array.
        entries = bytes.withUnsafeBytes { raw in
            let buffer = UnsafeRawBufferPointer(rebasing: raw[Offset.pieceIDs..<expectedSlotEnd])
            let array = Array(buffer.bindMemory(to: UInt64.self))
            return array.map { UInt64(littleEndian: $0) }
        }
        
        self.generation = decodedHeader.generation
                
        scanDeadCount()
    }
    
    private func scanDeadCount() {
        deadCount = entries.count { $0 == SlotMap.tombstoneValue }
    }
    
    func encode(into bytes: inout [UInt8]) {
        header.encode(into: &bytes)
        // Do NOT use key path here, it slows the code down by 45x
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
    subscript(range: PartialRangeThrough<Int>) -> ArraySlice<UInt64> {
        return entries[range]
    }

    subscript(range: PartialRangeFrom<Int>) -> ArraySlice<UInt64> {
        return entries[range]
    }

    subscript(range: PartialRangeUpTo<Int>) -> ArraySlice<UInt64> {
        return entries[range]
    }

    subscript(range: ClosedRange<Int>) -> ArraySlice<UInt64> {
        return entries[range]
    }

    subscript(range: Range<Int>) -> ArraySlice<UInt64> {
        return entries[range]
    }
    
    subscript(slot: Int) -> UInt64 {
        return entries[slot]
    }
    
    func isLive(_ slot: Int) -> Bool {
        return entries[slot] != SlotMap.tombstoneValue
    }
    
    /// Get the byte offset for a slot in the byte representation of SlotMap.
    /// - Parameter slot: The slot to get the offset for
    /// - Returns: The number of bytes that need to be offset to start at `slot`.
    func byteOffset(for slot: Int) -> UInt64 {
        return UInt64(Header.byteCount + (slot * MemoryLayout<UInt64>.size))
    }
    
    /// Appends the slot ids to the end of the entries list.
    ///
    /// After the ids are appended, the number of slots in the header is incremented.
    ///
    /// - Parameter ids: The ids to append.
    /// - Returns: The range at which the IDs were inserted. Used for writing into the ``VectorStoreFile``.
    @discardableResult
    func append(ids: [UInt64]) -> Range<Int> {
        let startRange = entries.count
        entries.append(contentsOf: ids)
        
        return startRange..<(startRange + ids.count)
    }
    
    /// "Deletes" a range of slots from the mapping.
    ///
    /// Internally this replaces entries with ``SlotMap/tombstoneValue``. This is because a deletion from the middle of the file would require re-writing the entire file after the deletion range. Instead of doing this, the slot map is occasionally compacted when ``SlotMap/deadFraction`` reaches ``SlotMap/acceptableDeadFraction``.
    ///
    /// - Parameter range: The range of slots to replace with ``SlotMap/tombstoneValue``
    func tombstone(range: Range<Int>) {
        guard range.lowerBound >= 0 && range.upperBound <= count else { return }
        var newlyDead = 0
        for slot in range where entries[slot] != SlotMap.tombstoneValue { newlyDead += 1 }
        deadCount += newlyDead
        
        let tombstones = [UInt64](repeating: SlotMap.tombstoneValue.littleEndian, count: range.count)

        entries.replaceSubrange(range, with: tombstones)
    }
}
