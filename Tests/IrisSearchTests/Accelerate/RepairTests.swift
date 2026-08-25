//
//  RepairTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/25/26.
//

import Foundation
import Testing
import GRDB
@testable import IrisSearch
@testable import IrisCommon

/// Covers `AccelerateIndex.repair`, which reconciles the on-disk index against SQLite after a crash
/// or a torn write. The corruption here is applied to the raw bytes of `doc.bin` and `slot.bin`
/// rather than simulated through the API, because the states repair exists to clean up are exactly
/// the ones the API cannot produce on purpose.
struct RepairTests {

    // MARK: - Fixtures

    /// `AccelerateIndex` only reads `dimension` from its provider — embedding happens upstream in
    /// `IrisDB`, so repair never calls `embed`.
    final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int
        init(dimension: Int) { self.dimension = dimension }
        func embed(content: String) async throws -> [Double] {
            fatalError("repair must never embed")
        }
    }

    static let dimensions = 4

    /// A one-hot unit vector, so scores are exact and a mismatched slot is obvious.
    static func vector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[axis % dimensions] = 1
        return v
    }

    /// A document whose pieces already carry the rowids SQLite would have assigned.
    static func document(id: Int64, title: String, pieceIDs: [Int64]) -> IrisDocument {
        var document = IrisDocument(uuid: UUID(), title: title, description: "d",
                                    pieces: pieceIDs.map { pieceID in
            var piece = DocumentPiece(
                content: .text(content: "piece \(pieceID)",
                               location: DocumentLocation(sequenceIndex: 0, documentLength: 1,
                                                          anchor: .text(characterRange: 0..<1))),
                embeddings: vector(Int(pieceID)),
                parentID: id)
            piece.id = pieceID
            return piece
        })
        document.id = id
        return document
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeIndex(at directory: URL) throws -> AccelerateIndex {
        try AccelerateIndex(indexLocation: directory, embeddingProvider: StubEmbedder(dimension: dimensions))
    }

    /// A pool holding only the `documents` table, which is all `repair` reads.
    static func makeDatabase(at directory: URL, containing documents: [IrisDocument]) throws -> DatabasePool {
        let pool = try DatabasePool(path: directory.appending(path: "map.sqlite").path(percentEncoded: false))
        try pool.write { db in
            try db.create(table: IrisDocument.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).unique().notNull()
                table.column("title", .text).unique().notNull()
                table.column("description", .text).notNull()
            }
            for var document in documents {
                try document.insert(db)
            }
        }
        return pool
    }

    // MARK: - Corruption helpers

    static func documentLogURL(in directory: URL) -> URL {
        directory.appending(path: "gen-0").appending(path: "doc.bin")
    }

    /// Drops every record past `keepingRecords`, standing in for a log whose tail never reached disk.
    /// The slots those records described stay committed in `slot.bin`, so they become orphans.
    static func truncateDocumentLog(in directory: URL, keepingRecords count: Int) throws {
        let offset = DocumentLog.Offset.records + count * DocumentLog.Record.byteCount
        let handle = try FileHandle(forWritingTo: documentLogURL(in: directory))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
    }

    /// Flips the stored checksum of one record so the loader rejects it, standing in for a torn
    /// write in the middle of the log rather than at its tail.
    static func corruptChecksum(ofRecord index: Int, in directory: URL) throws {
        let url = documentLogURL(in: directory)
        var bytes = try Data(contentsOf: url)
        let checksumByte = DocumentLog.Offset.records
            + index * DocumentLog.Record.byteCount
            + DocumentLog.Record.Offset.checksum
        bytes[checksumByte] ^= 0xFF
        try bytes.write(to: url)
    }

    /// Lops `bytes` off the end of the log, leaving it ending part way through a record. Stands in
    /// for an append that was interrupted mid-write rather than between records.
    static func tearLastRecord(in directory: URL, by bytes: Int = 30) throws {
        let url = documentLogURL(in: directory)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.truncate(atOffset: length - UInt64(bytes))
    }

    static func documentLogByteCount(in directory: URL) throws -> Int {
        try Data(contentsOf: documentLogURL(in: directory)).count
    }

    /// Liveness of every committed slot, read back from disk so the assertion covers what survives
    /// a reload rather than what happens to be in memory.
    static func slotLiveness(in directory: URL) throws -> [Bool] {
        let generation = try DatabaseGeneration.load(generation: 0, in: directory)
        return (0..<generation.slotMap.count).map { generation.slotMap.isLive($0) }
    }

    /// Builds an index of `documentCount` documents, two slots each, laid out contiguously from
    /// slot zero, committed to disk. Returns the documents in slot order.
    @discardableResult
    static func buildIndex(at directory: URL, documentCount: Int) throws -> [IrisDocument] {
        let index = try makeIndex(at: directory)
        let documents: [IrisDocument] = (0..<documentCount).map { position in
            let documentID = Int64(position + 1)
            let firstPieceID = Int64(100 + position * 2)
            let secondPieceID = firstPieceID + 1
            return document(id: documentID,
                            title: "document-\(position)",
                            pieceIDs: [firstPieceID, secondPieceID])
        }
        for document in documents {
            try index.addDocument(document: document)
        }
        try index.close()
        return documents
    }

    // MARK: - Nothing to do

    @Test func testRepairOnAConsistentIndexTombstonesNothing() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)
        try index.close()

        #expect(needsReindex.isEmpty)
        #expect(try Self.slotLiveness(in: dir) == [true, true, true, true, true, true])
    }

    @Test func testRepairIsIdempotent() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let first = try Self.makeIndex(at: dir)
        let firstResult = try first.repair(using: pool)
        try first.close()
        let afterFirst = try Self.slotLiveness(in: dir)

        let second = try Self.makeIndex(at: dir)
        let secondResult = try second.repair(using: pool)
        try second.close()

        #expect(Set(firstResult) == Set(secondResult),
                "A second repair must reach the same conclusion, not discover new damage.")
        #expect(try Self.slotLiveness(in: dir) == afterFirst)
    }

    // MARK: - Index ahead of SQLite

    @Test func testDocumentMissingFromSQLiteIsTombstoned() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        // The middle document's row is gone — a delete that landed in SQLite and not in the index.
        let pool = try Self.makeDatabase(at: dir, containing: [documents[0], documents[2]])

        let index = try Self.makeIndex(at: dir)
        _ = try index.repair(using: pool)
        try index.close()

        #expect(try Self.slotLiveness(in: dir) == [true, true, false, false, true, true],
                "Only the orphaned document's slots may be tombstoned.")
    }

    @Test func testDocumentMissingFromSQLiteStopsBeingSearchable() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        let pool = try Self.makeDatabase(at: dir, containing: [documents[0], documents[2]])

        let index = try Self.makeIndex(at: dir)
        let before = Set(try index.search(query: Self.vector(0), kItems: 10).map(\.id))
        #expect(before.contains(102), "The zombie document scores before repair.")

        _ = try index.repair(using: pool)

        let after = Set(try index.search(query: Self.vector(0), kItems: 10).map(\.id))
        #expect(after == [100, 101, 104, 105],
                "Vectors whose rows no longer exist must stop resolving to dead rowids.")
    }

    @Test func testDocumentMissingFromSQLiteIsNotReportedForReindexing() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 2)
        let pool = try Self.makeDatabase(at: dir, containing: [documents[0]])

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)

        #expect(needsReindex.isEmpty,
                "A document SQLite no longer knows about has nothing to re-embed from.")
    }

    // MARK: - Index behind SQLite

    @Test func testDocumentMissingFromTheIndexIsReportedForReindexing() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 2)
        let unindexed = Self.document(id: 99, title: "never-indexed", pieceIDs: [900, 901])
        let pool = try Self.makeDatabase(at: dir, containing: documents + [unindexed])

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)

        #expect(needsReindex == [unindexed.uuid])
    }

    @Test func testAnUncommittedAppendIsReportedForReindexing() throws {
        // Below the 32-slot sync threshold nothing commits, so an index dropped without `close`
        // loses the append entirely. The row is still in SQLite, so repair must ask for it back.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = Self.document(id: 1, title: "uncommitted", pieceIDs: [100, 101])
        let abandoned = try Self.makeIndex(at: dir)
        try abandoned.addDocument(document: document)
        // Deliberately no close() — this is the crash.

        let pool = try Self.makeDatabase(at: dir, containing: [document])
        let reopened = try Self.makeIndex(at: dir)

        #expect(reopened.needsRepair, "An uncommitted tail must be visible as damage.")
        #expect(try reopened.repair(using: pool) == [document.uuid])
    }

    @Test func testRepairClearsTheNeedsRepairFlag() throws {
        // The uncommitted entry bytes are what pin the flag, and `commit` is what trims them, so the
        // clear has to be observable in memory rather than only after a reload.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = Self.document(id: 1, title: "uncommitted", pieceIDs: [100, 101])
        let abandoned = try Self.makeIndex(at: dir)
        try abandoned.addDocument(document: document)

        let pool = try Self.makeDatabase(at: dir, containing: [document])
        let reopened = try Self.makeIndex(at: dir)
        #expect(reopened.needsRepair)

        _ = try reopened.repair(using: pool)
        #expect(!reopened.needsRepair)
    }

    @Test func testTheClearedFlagSurvivesAReload() throws {
        // The in-memory clear is worthless if the trimmed bytes are still on disk — the next open
        // would rediscover them and repair on every launch forever.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = Self.document(id: 1, title: "uncommitted", pieceIDs: [100, 101])
        let abandoned = try Self.makeIndex(at: dir)
        try abandoned.addDocument(document: document)

        let pool = try Self.makeDatabase(at: dir, containing: [document])
        let reopened = try Self.makeIndex(at: dir)
        _ = try reopened.repair(using: pool)
        try reopened.close()

        #expect(!(try Self.makeIndex(at: dir).needsRepair))
    }

    @Test func testCommitTrimsTheUncommittedTailFromDisk() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let document = Self.document(id: 1, title: "uncommitted", pieceIDs: [100, 101])
        let abandoned = try Self.makeIndex(at: dir)
        try abandoned.addDocument(document: document)

        let slotURL = dir.appending(path: "gen-0").appending(path: "slot.bin")
        let strayBytes = try Data(contentsOf: slotURL).count
        #expect(strayBytes == SlotMap.Header.byteCount + 2 * MemoryLayout<UInt64>.size,
                "Two entries were appended without ever being committed.")

        let pool = try Self.makeDatabase(at: dir, containing: [document])
        let reopened = try Self.makeIndex(at: dir)
        _ = try reopened.repair(using: pool)
        try reopened.close()

        #expect(try Data(contentsOf: slotURL).count == SlotMap.Header.byteCount,
                "The header commits to zero slots, so no entry bytes may remain.")
    }

    // MARK: - Damage the length check cannot see

    @Test func testACrashPartWayThroughADeleteIsDetected() throws {
        // Tombstoning rewrites entries in place, so slot.bin's length never moves and
        // `hasUncommittedTail` stays false. Only the coverage check sees this one: the record is
        // still live in the log while every slot it names is dead.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 2)

        let interrupted = try Self.makeIndex(at: dir)
        try interrupted.removeDocument(documentUUID: documents[1].uuid, documentID: 2, pieceIDs: [])
        try interrupted.close()
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)   // the live:false record never landed

        let generation = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(!generation.slotMap.hasUncommittedTail,
                "An in-place write leaves the file length untouched.")
        #expect(generation.documentLog.coveredSlotCount == 4)
        #expect(generation.slotMap.count - generation.slotMap.deadCount == 2)
        #expect(generation.needsRepair, "Coverage is the only term that can catch this.")
    }

    // MARK: - Torn trailing record

    @Test func testATornTrailingRecordIsTrimmedAtLoad() throws {
        // `append` writes at the file's end. Leaving a partial record there would put every later
        // record off the 64-byte stride the loader walks, so one torn write would corrupt the rest
        // of the log rather than costing a single record.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.buildIndex(at: dir, documentCount: 3)
        try Self.tearLastRecord(in: dir)
        #expect(try Self.documentLogByteCount(in: dir) % DocumentLog.Record.byteCount != 0,
                "Precondition: the file is misaligned before opening.")

        let generation = try DatabaseGeneration.load(generation: 0, in: dir)

        #expect(generation.documentLog.hasTornRecord)
        #expect(try Self.documentLogByteCount(in: dir) % DocumentLog.Record.byteCount == 0,
                "The partial record must be gone before anything can append past it.")
    }

    @Test func testARecordAppendedAfterATearIsStillReadable() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.tearLastRecord(in: dir)

        // Delete through the reopened index, which appends a record onto the trimmed file.
        let reopened = try Self.makeIndex(at: dir)
        try reopened.removeDocument(documentUUID: documents[0].uuid, documentID: 1, pieceIDs: [])
        try reopened.close()

        let generation = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(generation.documentLog.ranges[documents[0].uuid] == nil,
                "The delete landed on the stride and replayed correctly.")
        #expect(generation.documentLog.ranges[documents[1].uuid] != nil,
                "The surviving records were not shifted out of alignment.")
    }

    @Test func testTrimmingATearKeepsSupersededRecords() throws {
        // Regression: the trim point is the file's last whole record, not `ranges.count`. The log is
        // append-only, so a delete leaves more records on disk than there are live documents —
        // trimming to the live count would destroy the ones a delete or update superseded.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)

        let mutating = try Self.makeIndex(at: dir)
        try mutating.removeDocument(documentUUID: documents[0].uuid, documentID: 1, pieceIDs: [])
        try mutating.addDocument(document: Self.document(id: 4, title: "document-3", pieceIDs: [106, 107]))
        try mutating.close()

        // Five records on disk. Tearing the last leaves four whole ones, which fold down to two
        // live documents — so a trim derived from `ranges.count` would land at 192 bytes and eat
        // two records it had no business touching.
        try Self.tearLastRecord(in: dir)
        let generation = try DatabaseGeneration.load(generation: 0, in: dir)

        #expect(try Self.documentLogByteCount(in: dir)
                == DocumentLog.Offset.records + 4 * DocumentLog.Record.byteCount,
                "All four whole records must survive; only the partial bytes are cut.")
        #expect(generation.documentLog.ranges.count == 2)
        #expect(generation.documentLog.ranges[documents[1].uuid] != nil)
        #expect(generation.documentLog.ranges[documents[2].uuid] != nil)
        #expect(generation.documentLog.ranges[documents[0].uuid] == nil,
                "The delete record is one of the four that survived the trim.")
    }

    // MARK: - Corrupted document log: orphaned slots

    @Test func testOrphanedSlotsInTheMiddleOfTheMapAreTombstoned() throws {
        // A record that fails its checksum is skipped by the loader, but the slots it described are
        // still committed in slot.bin — live, and belonging to nothing.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.corruptChecksum(ofRecord: 1, in: dir)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)
        try index.close()

        #expect(try Self.slotLiveness(in: dir) == [true, true, false, false, true, true])
        #expect(needsReindex == [documents[1].uuid],
                "The document whose record was lost still exists in SQLite and must be re-indexed.")
    }

    @Test func testOrphanedSlotsAtTheEndOfTheMapAreTombstoned() throws {
        // Regression: a run of orphans that reaches the last slot has no following live slot to
        // close it, so a sweep that only tombstones on the falling edge silently skips it. Orphans
        // at the tail are the likely case — that is where an interrupted append leaves them.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)
        try index.close()

        #expect(try Self.slotLiveness(in: dir) == [true, true, true, true, false, false])
        #expect(needsReindex == [documents[2].uuid])
    }

    @Test func testEveryOrphanRunIsTombstonedWhenTheyAreNotAdjacent() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 4)
        try Self.corruptChecksum(ofRecord: 1, in: dir)
        try Self.corruptChecksum(ofRecord: 3, in: dir)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        let needsReindex = try index.repair(using: pool)
        try index.close()

        #expect(try Self.slotLiveness(in: dir) == [true, true, false, false, true, true, false, false],
                "A middle run and a trailing run must both be closed out.")
        #expect(Set(needsReindex) == Set([documents[1].uuid, documents[3].uuid]))
    }

    @Test func testTheWholeMapCanBeOrphaned() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 2)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 0)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        _ = try index.repair(using: pool)
        try index.close()

        #expect(try Self.slotLiveness(in: dir) == [false, false, false, false],
                "One run covering every slot still has to be tombstoned.")
    }

    @Test func testOrphanedSlotsStopReturningGarbageFromSearch() throws {
        // The point of the sweep: search filters on slot liveness, not on log coverage, so an
        // uncovered live slot is returned with whatever rowid its entry happens to hold.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        let before = Set(try index.search(query: Self.vector(0), kItems: 10).map(\.id))
        #expect(before == [100, 101, 102, 103, 104, 105],
                "Before repair the orphaned slots still score.")

        _ = try index.repair(using: pool)

        let after = Set(try index.search(query: Self.vector(0), kItems: 10).map(\.id))
        #expect(after == [100, 101, 102, 103])
    }

    @Test func testRepairSurvivesAReload() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 3)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)
        let pool = try Self.makeDatabase(at: dir, containing: documents)

        let index = try Self.makeIndex(at: dir)
        _ = try index.repair(using: pool)
        try index.close()

        let reopened = try Self.makeIndex(at: dir)
        let ids = Set(try reopened.search(query: Self.vector(0), kItems: 10).map(\.id))
        #expect(ids == [100, 101, 102, 103],
                "Repair commits its tombstones; they must not have to be rediscovered.")
    }

    // MARK: - Degenerate inputs

    @Test func testRepairOnAnEmptyIndexDoesNothing() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try Self.makeIndex(at: dir)
        let pool = try Self.makeDatabase(at: dir, containing: [])

        let index = try Self.makeIndex(at: dir)
        #expect(try index.repair(using: pool).isEmpty)
        #expect(try Self.slotLiveness(in: dir).isEmpty)
    }

    @Test func testAnImageOnlyDocumentIsLeftAlone() throws {
        // A document with no embeddable pieces owns an empty slot range and is still live. Repair
        // must not treat "no vectors" as damage, or every open would re-index it forever.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageOnly = IrisDocument(uuid: UUID(), title: "image-only", description: "d", pieces: [])
        var stored = imageOnly
        stored.id = 1

        let index = try Self.makeIndex(at: dir)
        try index.addDocument(document: stored)
        try index.close()

        let pool = try Self.makeDatabase(at: dir, containing: [stored])
        let reopened = try Self.makeIndex(at: dir)

        #expect(try reopened.repair(using: pool).isEmpty,
                "An empty range is the record of a document that had nothing to index.")
    }

    // MARK: - Detection through effects rather than flags

    @Test func testACorruptedDocumentLogRaisesNeedsRepair() throws {
        // slot.bin is clean here — it was committed before the damage — so the length check says
        // nothing. Coverage is what notices: the lost record's slots are still live and now belong
        // to no document.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.buildIndex(at: dir, documentCount: 3)
        try Self.truncateDocumentLog(in: dir, keepingRecords: 2)

        let generation = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(!generation.slotMap.hasUncommittedTail, "The slot map itself is intact.")
        #expect(generation.needsRepair)
    }

    @Test func testARejectedRecordAloneDoesNotPinNeedsRepair() throws {
        // A failed checksum is not a repair trigger in its own right: repair only appends to
        // doc.bin, so the bad bytes stay bad and the flag could never go back down. The damage is
        // caught through its effects instead, and here there are none — the rejected record is a
        // delete that the fold would have discarded anyway, so coverage still balances.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = try Self.buildIndex(at: dir, documentCount: 2)

        let mutating = try Self.makeIndex(at: dir)
        try mutating.removeDocument(documentUUID: documents[1].uuid, documentID: 2, pieceIDs: [])
        try mutating.close()

        try Self.corruptChecksum(ofRecord: 2, in: dir)   // the delete record

        let generation = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(generation.documentLog.rejectedRecords == 1)
        #expect(generation.needsRepair,
                "Not because a record was rejected, but because its slots are now dead while the document reads as live.")
    }
}
