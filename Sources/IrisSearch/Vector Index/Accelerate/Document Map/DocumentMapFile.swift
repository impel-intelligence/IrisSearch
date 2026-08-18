//
//  DocumentMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class DocumentMapFile {
    let file: BinaryFile
    let map: DocumentMap
    let url: URL

    public init(url: URL, maximumSlotCount: Int) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        map = try DocumentMap(bytes: data.byteArray, maximumSlotCount: maximumSlotCount)
        file = try BinaryFile(url: url)
    }
    
    public static func new(at url: URL, maximumSlotCount: Int, generation: UInt64 = 0) throws -> DocumentMapFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = DocumentMap(generation: generation).encoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try DocumentMapFile(url: url, maximumSlotCount: maximumSlotCount)
    }
}

// MARK: Writing
extension DocumentMapFile {
    @discardableResult
    func append(uuid: UUID, documentID: UInt64, slots: Range<Int>, live: Bool) throws -> DocumentMap.Record {
        let record = DocumentMap.Record(uuid: uuid,
                                        documentID: documentID,
                                        startSlot: UInt64(slots.lowerBound),
                                        endSlot: UInt64(slots.upperBound),
                                        sequence: map.nextSequence,
                                        flags: live ? [.live] : .empty)

        try file.append(data: Data(record.encoded()))
        map.apply(record: record)
        return record
    }
    
    @discardableResult
    func remove(uuid: UUID, documentID: UInt64) throws -> Range<Int> {
        guard let documentRange = map.ranges[uuid] else {
            throw DocumentMapError.rangeDoesNotExist(uuid: uuid)
        }
        
        try append(uuid: uuid, documentID: documentID, slots: documentRange.range, live: false)
        
        return documentRange.range
    }
}
