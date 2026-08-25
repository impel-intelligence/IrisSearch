//
//  SlotMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class SlotMapFile {
    private let file: BinaryFile
    private let map: SlotMap
    private let url: URL
    
    public var count: Int { map.count }
    public var deadCount: Int { map.deadCount }
    public var deadFraction: Double { map.deadFraction }

    /// Whether the file carries entry bytes past the slot count its header commits to.
    ///
    /// This is a narrower claim than "the process shut down cleanly", and the difference matters.
    /// Tombstoning rewrites entries **in place**, so the file length never moves — a crash part way
    /// through a delete leaves no trace here at all. Divergence on the delete path is caught by the
    /// coverage check in ``DatabaseGeneration/needsRepair``, not by this flag.
    ///
    /// ``commit()`` trims the uncommitted tail away, so a committed file always reports `false`.
    private(set) var hasUncommittedTail: Bool

    /// The byte length this file would have if every in-memory entry were committed.
    private var committedLength: Int { SlotMap.Header.byteCount + map.count * MemoryLayout<UInt64>.size }

    public init(url: URL) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        map = try SlotMap(bytes: data.byteArray)
        file = try BinaryFile(url: url)
            
        // Spelled out rather than via `committedLength`: `self` is not usable until every stored
        // property is initialised, and this is the last one.
        hasUncommittedTail = data.count != SlotMap.Header.byteCount + map.count * MemoryLayout<UInt64>.size
    }
    
    public static func new(at url: URL, generation: UInt64 = 0) throws -> SlotMapFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = SlotMap(entries: [], generation: generation).encoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try SlotMapFile(url: url)
    }
        
    /// Appends the slot ids to the end of the entries list.
    ///
    /// IDs are appended to the in-memory map and the file.The header is **not** persisted to disk here. The core reason for this is ordering the writes to disk. Since the header lives in the first section of the file, it would require two write calls to add. Two different write calls can not be ensured to reach disk at the same time. Because of this ``SlotMap.Header`` is written during the ``SlotMapFile/commit`` which is called from ``DatabaseGeneration/flush``..
    ///
    /// - Parameter ids: The ids to append.
    /// - Returns: The range at which the IDs were inserted. Used for writing into the ``VectorStoreFile``.
    @discardableResult
    func append(contentsOf ids: [UInt64]) throws -> Range<Int> {
        // Append to the in-memory array.
        let range = map.append(ids: ids)
        
        // Get the first bye offset for the start of the range.
        let startOffset = map.byteOffset(for: range.lowerBound)
        
        // Write the new contents to the file.
        try ids.map { $0.littleEndian }.withUnsafeBytes { buffer in
            try file.write(data: Data(buffer), at: startOffset)
        }
        
        return range
    }
    
    /// "Deletes" a range of slots from the mapping.
    ///
    /// Internally this replaces entries with ``SlotMap/tombstoneValue``. This is because a deletion from the middle of the file would require re-writing the entire file after the deletion range. Instead of doing this, the slot map is occasionally compacted when ``SlotMap/deadFraction`` reaches ``SlotMap/acceptableDeadFraction``.
    ///
    /// This function also writes the new tombstones to disk using `file.write`. This does not sync the contents to disk. Syncing is handled by one level up (``DatabaseGeneration``)
    ///
    /// - Parameter range: The range of slots to replace with ``SlotMap/tombstoneValue``
    func tombstone(range: Range<Int>) throws {
        guard range.lowerBound >= 0 && range.upperBound <= map.count else {
            Log.logger.warning("Tombstone out of range, skipping because the document does not exist.")
            return
        }
        
        try map.tombstone(range: range)
        
        // Find where the tomb-stoning starts
        let tombstoneStartPoint = map.byteOffset(for: range.lowerBound)
        let tombstones = [UInt64](repeating: SlotMap.tombstoneValue.littleEndian, count: range.count)

        try tombstones.withUnsafeBytes { buffer in
            try file.write(data: Data(buffer), at: tombstoneStartPoint)
        }
    }
    
    /// Persist the header onto disk, this is a small 64 byte write to keep slot count up to date on disk without writing the entire file.
    func writeHeader() throws {
        let header = map.header.encoded()
        try file.write(data: Data(header), at: 0)
    }
    
    /// Synchronizes the file to disk, ensuring it is saved
    func synchronizeFile() throws {
        try file.synchronize()
    }
    
    /// Fully synchronizes the file to disk, ensuring it is actually written. This is only different from `synchronizeFile` on Darwin.
    func fullSynchronizeFile() throws {
        try file.fullSynchronize()
    }
    
    /// Writes the slot map header to disk then updates the durable slot tracker.
    ///
    /// This is considered a "commit" as the entire initialization of a ``DatabaseGeneration`` is based on the count found by ``SlotMapFile``. If this commit never reaches disk, the next load will result in any new appends being ignored.
    ///
    /// The durable slot tracker `durableUpToSlot` represents the last slot that has been confirmed to be on disk (through `file.synchronize()`.
    func commit() throws {
        try writeHeader()
        try file.scale(to: UInt64(committedLength))
        try synchronizeFile()
        hasUncommittedTail = false
    }
        
    subscript(range: PartialRangeThrough<Int>) -> ArraySlice<UInt64> { map[range] }

    subscript(range: PartialRangeFrom<Int>) -> ArraySlice<UInt64> { map[range] }

    subscript(range: PartialRangeUpTo<Int>) -> ArraySlice<UInt64> { map[range] }

    subscript(range: ClosedRange<Int>) -> ArraySlice<UInt64> { map[range] }

    subscript(range: Range<Int>) -> ArraySlice<UInt64> { map[range] }
    
    subscript(slot: Int) -> UInt64 { map[slot] }
    
    func isLive(_ slot: Int) -> Bool { map.isLive(slot) }
}
