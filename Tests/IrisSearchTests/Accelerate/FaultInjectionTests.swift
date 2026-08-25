//
//  FaultInjectionTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/25/26.
//
//  §13 of docs/VECTOR_INDEX_IMPLEMENTATION.md: for each fault point, build a fixture, install an
//  injector that throws there, attempt the operation, close, reopen, and assert the index did not
//  land somewhere between the pre- and post-operation states.
//
//  WHAT THESE TESTS DO NOT COVER: true power loss is not reproducible in process. A thrown injector
//  models the write returning an error, and abandoning the index without `close` models the process
//  dying with the page cache intact — which §2 calls the overwhelmingly likely case. The fsync
//  *ordering* in §2 and §7, which is what protects against a kernel panic or a lost device write
//  cache, is reasoned rather than tested. Do not read a green run here as coverage of that.

import Foundation
import Testing
import GRDB
@testable import IrisSearch
@testable import IrisCommon

struct FaultInjectionTests {

    // MARK: - Fixtures

    final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int
        init(dimension: Int) { self.dimension = dimension }
        func embed(content: String) async throws -> [Double] {
            fatalError("the index is handed already-embedded content")
        }
    }

    struct InjectedFault: Error, Equatable {
        let point: FaultPoint
    }

    static let dimensions = 4

    static func vector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[axis % dimensions] = 1
        return v
    }

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

    /// An injector that throws at exactly one point and lets every other point through.
    static func injector(throwingAt target: FaultPoint) -> FaultInjector {
        { point in
            guard point == target else { return }
            throw InjectedFault(point: target)
        }
    }

    static func makeDatabase(at directory: URL, containing documents: [IrisDocument]) throws -> DatabasePool {
        let pool = try DatabasePool(path: directory.appending(path: "map.sqlite").path(percentEncoded: false))
        try pool.write { db in
            try db.create(table: IrisDocument.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).unique().notNull()
                table.column("title", .text).unique().notNull()
                table.column("description", .text).notNull()
            }
            try db.execute(sql: "DELETE FROM \(IrisDocument.databaseTableName)")
            for var document in documents {
                try document.insert(db)
            }
        }
        return pool
    }

    // MARK: - The invariants

    /// The subset of §14's checklist that a half-finished mutation can actually violate.
    ///
    /// Returns a description per violation rather than a bool so a failing sweep says which point
    /// broke which rule, instead of only that one of fifteen points is bad.
    static func inconsistencies(in generation: DatabaseGeneration) -> [String] {
        var problems: [String] = []
        let slotCount = generation.slotMap.count
        var owner = [UUID?](repeating: nil, count: slotCount)

        for (uuid, record) in generation.documentLog.ranges {
            // §14.6 — slotStart <= slotEnd <= slotCount.
            guard record.startSlot <= record.endSlot, record.endSlot <= slotCount else {
                problems.append("record \(uuid) spans \(record.startSlot)..<\(record.endSlot) of \(slotCount) slots")
                continue
            }

            for slot in record.range {
                // §14.3 — live ranges are disjoint.
                if let existing = owner[slot] {
                    problems.append("slot \(slot) is claimed by both \(existing) and \(uuid)")
                }
                owner[slot] = uuid

                // §14.4 — no slot inside a live range is tombstoned.
                if !generation.slotMap.isLive(slot) {
                    problems.append("live document \(uuid) owns tombstoned slot \(slot)")
                }
            }
        }

        // The other direction: a live slot no live document accounts for is returned by search with
        // whatever rowid its entry happens to hold.
        for slot in 0..<slotCount where generation.slotMap.isLive(slot) && owner[slot] == nil {
            problems.append("live slot \(slot) belongs to no document")
        }

        return problems
    }

    static func inconsistencies(inIndexAt directory: URL) throws -> [String] {
        let current = DatabaseGeneration.getCurrentDatabase(in: directory) ?? 0
        return inconsistencies(in: try DatabaseGeneration.load(generation: current, in: directory))
    }

    /// Every piece id search can currently reach, which is what a user would actually observe.
    static func searchableIDs(in index: AccelerateIndex) throws -> Set<Int> {
        var found: Set<Int> = []
        for axis in 0..<dimensions {
            found.formUnion(try index.search(query: vector(axis), kItems: 64).map(\.id))
        }
        return found
    }

    // MARK: - Interrupted insert

    @Test("An interrupted insert leaves the index consistent, or repairable into consistency.",
          arguments: FaultPoint.allCases)
    func testAnInterruptedInsertIsRecoverable(point: FaultPoint) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = [Self.document(id: 1, title: "a", pieceIDs: [100, 101]),
                        Self.document(id: 2, title: "b", pieceIDs: [102, 103])]

        let seeded = try Self.makeIndex(at: dir)
        for document in existing { try seeded.addDocument(document: document) }
        try seeded.close()

        // Rule 1: SQLite commits first, so the new document is already a row when the index write
        // is attempted. That is what makes the index — not SQLite — the side that can lag.
        let arriving = Self.document(id: 3, title: "c", pieceIDs: [104, 105])
        let pool = try Self.makeDatabase(at: dir, containing: existing + [arriving])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)

        try? index.addDocument(document: arriving)
        try? index.close()

        index.faultInjector = nil
        let reopened = try Self.makeIndex(at: dir)

        let damage = try Self.inconsistencies(inIndexAt: dir)
        if !damage.isEmpty {
            #expect(reopened.needsRepair,
                    "\(point) left \(damage) but the index reports healthy, so nothing would repair it")
        }

        _ = try reopened.repair(using: pool)
        try reopened.close()

        let remaining = try Self.inconsistencies(inIndexAt: dir)
        #expect(remaining.isEmpty, "after repair, \(point) still leaves: \(remaining)")
    }

    @Test("An interrupted insert never leaves the new document half-visible.",
          arguments: FaultPoint.allCases)
    func testAnInterruptedInsertIsAllOrNothing(point: FaultPoint) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = [Self.document(id: 1, title: "a", pieceIDs: [100, 101]),
                        Self.document(id: 2, title: "b", pieceIDs: [102, 103])]

        let seeded = try Self.makeIndex(at: dir)
        for document in existing { try seeded.addDocument(document: document) }
        try seeded.close()

        let arriving = Self.document(id: 3, title: "c", pieceIDs: [104, 105])
        let pool = try Self.makeDatabase(at: dir, containing: existing + [arriving])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)
        try? index.addDocument(document: arriving)
        try? index.close()

        index.faultInjector = nil
        let reopened = try Self.makeIndex(at: dir)
        _ = try reopened.repair(using: pool)

        let visible = try Self.searchableIDs(in: reopened)
        #expect(visible == [100, 101, 102, 103] || visible == [100, 101, 102, 103, 104, 105],
                "\(point) left a partial document visible: \(visible.sorted())")
    }

    // MARK: - Interrupted delete

    @Test("An interrupted delete leaves the index consistent, or repairable into consistency.",
          arguments: FaultPoint.allCases)
    func testAnInterruptedDeleteIsRecoverable(point: FaultPoint) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = [Self.document(id: 1, title: "a", pieceIDs: [100, 101]),
                         Self.document(id: 2, title: "b", pieceIDs: [102, 103]),
                         Self.document(id: 3, title: "c", pieceIDs: [104, 105])]

        let seeded = try Self.makeIndex(at: dir)
        for document in documents { try seeded.addDocument(document: document) }
        try seeded.close()

        // SQLite commits first here too, so the row is already gone when the index write fails.
        let pool = try Self.makeDatabase(at: dir, containing: [documents[0], documents[2]])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)
        try? index.removeDocument(documentUUID: documents[1].uuid, documentID: 2, pieceIDs: [])
        try? index.close()

        index.faultInjector = nil
        let reopened = try Self.makeIndex(at: dir)

        let damage = try Self.inconsistencies(inIndexAt: dir)
        if !damage.isEmpty {
            #expect(reopened.needsRepair,
                    "\(point) left \(damage) but the index reports healthy, so nothing would repair it")
        }

        _ = try reopened.repair(using: pool)
        try reopened.close()

        let remaining = try Self.inconsistencies(inIndexAt: dir)
        #expect(remaining.isEmpty, "after repair, \(point) still leaves: \(remaining)")
    }

    @Test("A deleted document never comes back, however the delete was interrupted.",
          arguments: FaultPoint.allCases)
    func testAnInterruptedDeleteNeverResurrectsTheDocument(point: FaultPoint) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = [Self.document(id: 1, title: "a", pieceIDs: [100, 101]),
                         Self.document(id: 2, title: "b", pieceIDs: [102, 103]),
                         Self.document(id: 3, title: "c", pieceIDs: [104, 105])]

        let seeded = try Self.makeIndex(at: dir)
        for document in documents { try seeded.addDocument(document: document) }
        try seeded.close()

        let pool = try Self.makeDatabase(at: dir, containing: [documents[0], documents[2]])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)
        try? index.removeDocument(documentUUID: documents[1].uuid, documentID: 2, pieceIDs: [])
        try? index.close()

        index.faultInjector = nil
        let reopened = try Self.makeIndex(at: dir)
        _ = try reopened.repair(using: pool)

        let visible = try Self.searchableIDs(in: reopened)
        #expect(visible.isDisjoint(with: [102, 103]),
                "\(point) left the deleted document searchable: \(visible.sorted())")
    }

    // MARK: - Retry

    @Test("Re-running an insert after a fault produces no duplicate.",
          arguments: FaultPoint.allCases)
    func testRetryingAnInterruptedInsertProducesNoDuplicate(point: FaultPoint) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = Self.document(id: 1, title: "a", pieceIDs: [100, 101])
        let seeded = try Self.makeIndex(at: dir)
        try seeded.addDocument(document: existing)
        try seeded.close()

        let arriving = Self.document(id: 2, title: "b", pieceIDs: [102, 103])
        let pool = try Self.makeDatabase(at: dir, containing: [existing, arriving])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)
        try? index.addDocument(document: arriving)
        try? index.close()

        index.faultInjector = nil
        let recovered = try Self.makeIndex(at: dir)
        let needsReindex = try recovered.repair(using: pool)

        // Repair reports what SQLite still has and the index lost; re-driving it is the caller's job.
        for uuid in needsReindex where uuid == arriving.uuid {
            try recovered.addDocument(document: arriving)
        }
        try recovered.close()

        let final = try Self.makeIndex(at: dir)
        let hits = try final.search(query: Self.vector(Int(103)), kItems: 64).map(\.id)
        #expect(hits.count == Set(hits).count, "\(point) produced duplicate slots for the same piece")
        #expect(try Self.inconsistencies(inIndexAt: dir).isEmpty)
    }

    // MARK: - Interrupted compaction

    @Test("An interrupted compaction leaves `current` naming a generation that loads and is consistent.",
          arguments: FaultPoint.allCases)
    func testAnInterruptedCompactionIsRecoverable(point: FaultPoint) async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let documents = [Self.document(id: 1, title: "a", pieceIDs: [100, 101]),
                         Self.document(id: 2, title: "b", pieceIDs: [102, 103]),
                         Self.document(id: 3, title: "c", pieceIDs: [104, 105])]

        let seeded = try Self.makeIndex(at: dir)
        for document in documents { try seeded.addDocument(document: document) }
        try seeded.removeDocument(documentUUID: documents[1].uuid, documentID: 2, pieceIDs: [])
        try seeded.close()

        let pool = try Self.makeDatabase(at: dir, containing: [documents[0], documents[2]])

        let index = try Self.makeIndex(at: dir)
        index.faultInjector = Self.injector(throwingAt: point)
        try? await index.compact()
        try? index.close()

        index.faultInjector = nil

        // Whatever `current` names has to be openable — a pointer at a generation that cannot load
        // is an index that never opens again.
        let reopened = try Self.makeIndex(at: dir)
        _ = try reopened.repair(using: pool)
        try reopened.close()

        let remaining = try Self.inconsistencies(inIndexAt: dir)
        #expect(remaining.isEmpty, "after repair, \(point) still leaves: \(remaining)")

        let visible = try Self.searchableIDs(in: try Self.makeIndex(at: dir))
        #expect(visible.isDisjoint(with: [102, 103]), "the deleted document survived compaction")
        #expect(visible.isSuperset(of: [100, 101, 104, 105]),
                "\(point) lost a live document: \(visible.sorted())")
    }
}
