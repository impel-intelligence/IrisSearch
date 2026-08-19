//
//  SlotMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class SlotMapFile {
    let file: BinaryFile
    let map: SlotMap
    let url: URL

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
    
    
    @discardableResult
    func append(contentsOf array: [UInt64]) throws -> Range<Int> {
        // Append to the in-memory array.
        let range = map.append(contentsOf: array)
        
        // Get the first bye offset for the start of the range.
        let startOffset = map.byteOffset(for: range.lowerBound)
        
        // Write the new contents to the file.
        try array.withUnsafeBytes { buffer in
            try file.write(data: Data(buffer), at: startOffset)
        }
    }

    func tombstone(range: Range<Int>) throws {
        
    }

    func writeSlots() throws {
        let size = map.encoded()
    }
    
    /// Persist the header onto disk, this is a small 64 byte write to keep slot count up to date on disk without writing the entire file.
    func writeHeader() throws {
        let header = map.header.encoded()
        try file.write(data: Data(header), at: 0)
    }
}
