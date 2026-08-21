//
//  DocumentMap.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

import Foundation
import CryptoSwift
import System

enum DocumentMapError: Error, Equatable {
    case notADocumentMap
    case truncatedFile(found: Int, needed: Int)
    case unsupportedVersion(found: UInt32, supported: UInt32)
    case checksumMismatch(found: UInt32, expected: UInt32)
    case recordPastMaximumSlots(recordEnd: Int, maximumSlots: Int)
    case recordStartAfterRecordEnd(recordStart: Int, recordEnd: Int)
    case rangeDoesNotExist(uuid: UUID)
}

final class DocumentLog {
    struct DocumentRange {
        let id: UInt64
        let startSlot: Int
        let endSlot: Int
        
        var range: Range<Int> { startSlot..<endSlot }
        
        init(id: UInt64, startSlot: Int, endSlot: Int) {
            self.id = id
            self.startSlot = startSlot
            self.endSlot = endSlot
        }
        
        init(_ record: Record) {
            id = record.documentID
            startSlot = Int(record.startSlot)
            endSlot = Int(record.endSlot)
        }
    }
    
    struct Record: DataExpressible {
        enum Offset {
            static let uuid = 0
            static let documentID = 16
            static let startSlot = 24
            static let endSlot = 32
            static let sequence = 40
            static let flags = 48
            static let checksum = 52
        }

        struct Flags: OptionSet {
            let rawValue: UInt8
            
            static let live = Flags(rawValue: 1 << 0)
            
            static let empty: Flags = []
        }

        static let byteCount: Int = 64
        
        var isLive: Bool { flags.contains(.live) }
        
        var uuid: UUID
        var documentID: UInt64
        var startSlot: UInt64
        var endSlot: UInt64
        var sequence: UInt64
        var flags: Flags
        
        init(uuid: UUID, documentID: UInt64, startSlot: UInt64, endSlot: UInt64, sequence: UInt64, flags: Flags) {
            self.uuid = uuid
            self.documentID = documentID
            self.startSlot = startSlot
            self.endSlot = endSlot
            self.sequence = sequence
            self.flags = flags
        }
        
        init(bytes: [UInt8], at base: Int, maximumSlotCount: Int) throws {
            // Make sure we have at least the minimum amount of bytes needed for the header.
            guard bytes.count >= base + Self.byteCount else {
                throw DocumentMapError.truncatedFile(found: bytes.count, needed: Self.byteCount)
            }
                        
            let storedCRC: UInt32 = bytes.load(at: base + Offset.checksum)
            let computedCRC: UInt32 = Checksum.crc32(Array(bytes[base..<base + Offset.checksum]))
            guard storedCRC == computedCRC else {
                throw DocumentMapError.checksumMismatch(found: storedCRC, expected: computedCRC)
            }
            
            uuid = bytes.loadUUID(at: base + Offset.uuid)
            documentID = bytes.load(at: base + Offset.documentID)
            startSlot = bytes.load(at: base + Offset.startSlot)
            endSlot = bytes.load(at: base + Offset.endSlot)
            sequence = bytes.load(at: base + Offset.sequence)
            flags = Flags(rawValue: bytes.load(at: base + Offset.flags))
            
            guard startSlot <= endSlot else {
                throw DocumentMapError.recordStartAfterRecordEnd(recordStart: Int(startSlot), recordEnd: Int(endSlot))
            }
            
            guard endSlot <= maximumSlotCount else {
                throw DocumentMapError.recordPastMaximumSlots(recordEnd: Int(endSlot), maximumSlots: maximumSlotCount)
            }
        }

        func encode(into bytes: inout [UInt8]) {
            let base = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: Self.byteCount))
            bytes.store(uuid, at: base + Offset.uuid)
            bytes.store(documentID, at: base + Offset.documentID)
            bytes.store(startSlot, at: base + Offset.startSlot)
            bytes.store(endSlot, at: base + Offset.endSlot)
            bytes.store(sequence, at: base + Offset.sequence)
            bytes.store(flags.rawValue, at: base + Offset.flags)
            
            // Take a checksum of the first 52 bytes and store it.
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
    
    struct Header: DataExpressible {
        enum Offset {
            static let magic = 0
            static let version = 4
            static let generation = 8
        }
        
        static let magic = Array("IDOC".utf8)
        static let byteCount: Int = 64
        static let version: UInt32 = 1
        
        var generation: UInt64
        
        public init(generation: UInt64) {
            self.generation = generation
        }

        public init(bytes: [UInt8]) throws {
            // Make sure we have at least the minimum amount of bytes needed for the header.
            guard bytes.count >= Self.byteCount else {
                throw DocumentMapError.truncatedFile(found: bytes.count, needed: Self.byteCount)
            }
            
            // Subscripts are absolute, so slices need `base`. `load(at:)` rebases off startIndex
            // itself, so it takes the field offset bare — adding `base` there would count
            // startIndex twice. See the note on `load(at:)` in BitWriting.swift.
            let base = bytes.startIndex

            let magic = Array(bytes[base..<base + Self.magic.count])
            guard magic == Self.magic else {
                throw DocumentMapError.notADocumentMap
            }

            let version: UInt32 = bytes.load(at: Offset.version)
            guard version == Self.version else {
                throw DocumentMapError.unsupportedVersion(found: version, supported: Self.version)
            }

            self.generation = bytes.load(at: Offset.generation)
        }

        func encode(into bytes: inout [UInt8]) {
            let base = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: Self.byteCount))
            bytes.replaceSubrange(base ..< base + Self.magic.count, with: Self.magic)
            bytes.store(DocumentLog.Header.version, at: base + Offset.version)
            bytes.store(generation, at: base + Offset.generation)
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
        static let records = 64
    }
    
    private(set) var ranges: [UUID: DocumentRange]
    private(set) var deadCount: Int = 0
    private(set) var nextSequence: UInt64 = 0

    private(set) var header: DocumentLog.Header
    
    public var count: Int { ranges.count }
    public var deadFraction: Double { count == 0 ? 0 : Double(deadCount) / Double(count) }
    
    var byteCount: Int {
        DocumentLog.Header.byteCount + (count * Record.byteCount)
    }
    
    init(generation: UInt64) {
        header = DocumentLog.Header(generation: generation)
        ranges = [:]
    }
    
    init(bytes: [UInt8], maximumSlotCount: Int) throws {
        header = try DocumentLog.Header(bytes: bytes)
        ranges = [:]
        
        let recordBytes = bytes.count - Offset.records
        let expectedRecordEnd = Offset.records + ((recordBytes / Record.byteCount) * Record.byteCount)
        
        guard expectedRecordEnd >= Offset.records else {
            return
        }
        
        var unfilteredRecords: [Record] = []
        
        for base in stride(from: Offset.records, to: expectedRecordEnd, by: Record.byteCount) {
            guard let record = try? Record(bytes: bytes, at: base, maximumSlotCount: maximumSlotCount) else {
                continue
            }
            
            unfilteredRecords.append(record)
        }

        for record in unfilteredRecords.sorted(by: { $0.sequence < $1.sequence }) {
            // isLive tells us if the record has been deleted, since document map is an append only log a non-live record needs to set the range to nil if it has previously been accounted for as live.
            ranges[record.uuid] = record.isLive ? DocumentRange(record) : nil
            
            if Int(record.sequence) > nextSequence {
                nextSequence = record.sequence + 1
            }
        }
    }
    
    /// Appends the serialized record. There is no offset parameter: the destination's current end *is* the offset, so callers cannot pass an inconsistent one.
    func compactedEncoding(into bytes: inout [UInt8]) {
        header.encode(into: &bytes)
        
        var localSequence = 0
        for (uuid, range) in ranges {
            let record = Record(uuid: uuid, documentID: range.id, startSlot: UInt64(range.startSlot), endSlot: UInt64(range.endSlot), sequence: UInt64(localSequence), flags: [.live])
            record.encode(into: &bytes)
            localSequence += 1
        }
    }

    func compactEncoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        compactedEncoding(into: &bytes)
        return bytes
    }
}

extension DocumentLog {
    func apply(record: DocumentLog.Record) {
        ranges[record.uuid] = record.isLive ? DocumentRange(record) : nil
        nextSequence = max(nextSequence, record.sequence + 1)
    }
}
