//
//  DocumentMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class DocumentLogFile {
    private let file: BinaryFile
    private let log: DocumentLog
    private let url: URL
    
    var ranges: [UUID: DocumentLog.DocumentRecord] { log.ranges }
    var rejectedRecords: Int { log.rejectedRecords }
    var coveredSlotCount: Int { log.coveredSlotCount }

    /// Whether the file ended part way through a record when it was opened.
    ///
    /// Alignment is a property of the bytes, not of the fold, so it is tracked here where the file
    /// length is known rather than in ``DocumentLog``, which only ever sees a decoded slice.
    ///
    /// This starts false on any file this initialiser has finished with: a partial tail is cut
    /// before the initialiser returns, because ``append(uuid:documentID:slots:live:)`` writes at the
    /// file's end. Leaving 30 stray bytes there would put every later record off the 64-byte stride
    /// the loader walks, turning one torn write into a log that decodes as garbage from that point on.
    private(set) var hasTornRecord: Bool = false

    public init(url: URL, maximumSlotCount: Int) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        log = try DocumentLog(bytes: data.byteArray, maximumSlotCount: maximumSlotCount)
        file = try BinaryFile(url: url)

        // One past the last whole record the file holds. Derived from the byte count, never from
        // `ranges.count` — the log is append-only, so it keeps a record per mutation while `ranges`
        // keeps one entry per surviving document. Truncating to the latter would delete every
        // record that a delete or an update superseded.
        let recordBytes = data.count - DocumentLog.Offset.records
        let wholeRecordEnd = DocumentLog.Offset.records + ((recordBytes / DocumentLog.Record.byteCount) * DocumentLog.Record.byteCount)

        if recordBytes % DocumentLog.Record.byteCount != 0 {
            hasTornRecord = true
            try file.scale(to: UInt64(wholeRecordEnd))
        }
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
        guard let documentRange = log.ranges[uuid] else {
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
                                        sequence: log.nextSequence,
                                        flags: live ? [.live] : .empty)

        try file.append(data: Data(record.encoded()))
        log.apply(record: record)
        return record
    }
    
    /// Synchronizes the file to disk, ensuring it is saved
    func synchronizeFile() throws {
        try file.synchronize()
    }
    
    /// Fully synchronizes the file to disk, ensuring it is actually written. This is only different from `synchronizeFile` on Darwin.
    func fullSynchronizeFile() throws {
        try file.fullSynchronize()
    }
}
