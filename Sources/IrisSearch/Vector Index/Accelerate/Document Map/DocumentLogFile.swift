//
//  DocumentMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class DocumentLogFile {
    private let file: BinaryFile
    private let map: DocumentLog
    private let url: URL

    public init(url: URL, maximumSlotCount: Int) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        map = try DocumentLog(bytes: data.byteArray, maximumSlotCount: maximumSlotCount)
        file = try BinaryFile(url: url)
    }
    
    public static func new(at url: URL, maximumSlotCount: Int, generation: UInt64 = 0) throws -> DocumentLogFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = DocumentLog(generation: generation).compactEncoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try DocumentLogFile(url: url, maximumSlotCount: maximumSlotCount)
    }
}

// MARK: Writing
extension DocumentLogFile {
    func range(for uuid: UUID) throws -> Range<Int> {
        guard let documentRange = map.ranges[uuid] else {
            throw DocumentMapError.rangeDoesNotExist(uuid: uuid)
        }
        return documentRange.range
    }
    
    @discardableResult
    func append(uuid: UUID, documentID: UInt64, slots: Range<Int>, live: Bool) throws -> DocumentLog.Record {
        let record = DocumentLog.Record(uuid: uuid,
                                        documentID: documentID,
                                        startSlot: UInt64(slots.lowerBound),
                                        endSlot: UInt64(slots.upperBound),
                                        sequence: map.nextSequence,
                                        flags: live ? [.live] : .empty)

        try file.append(data: Data(record.encoded()))
        map.apply(record: record)
        return record
    }
    
    /// Synchronizes the file to disk, ensuring it is saved
    func synchronizeFile() throws {
        try file.synchronize()
    }
}
