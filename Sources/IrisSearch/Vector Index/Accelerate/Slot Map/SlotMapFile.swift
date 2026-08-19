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
    
    /// The count of slots that have been confirmed to be synced to disk.
    private var durableUpToSlot: Int = 0

    public init(url: URL) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        map = try SlotMap(bytes: data.byteArray)
        file = try BinaryFile(url: url)
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
        guard range.lowerBound >= 0 && range.upperBound <= map.count else { return }
        
        map.tombstone(range: range)
        
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
    
    /// Writes the slot map header to disk then updates the durable slot tracker.
    ///
    /// This is considered a "commit" as the entire initialization of a ``DatabaseGeneration`` is based on the count found by ``SlotMapFile``. If this commit never reaches disk, the next load will result in any new appends being ignored.
    ///
    /// The durable slot tracker `durableUpToSlot` represents the last slot that has been confirmed to be on disk (through `file.synchronize()`.
    func commit() throws {
        try writeHeader()
        try synchronizeFile()
        durableUpToSlot = map.count
    }
    
    subscript(slot: Int) -> UInt64 { map[slot] }
    
    func isLive(_ slot: Int) -> Bool { map.isLive(slot) }
}
