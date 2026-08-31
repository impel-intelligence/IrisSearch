//
//  CompactorTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/20/26.
//

import Foundation
import Testing
@testable import IrisSearch
@testable import IrisCommon

struct CompactorTests {

    // MARK: - Fixtures

    static let dimensions = 4

    /// Every component distinct and derived from `seed`, so a partially copied vector shows up as a
    /// trailing run of zeros rather than as a plausible value.
    static func vector(_ seed: Float) -> [Float] {
        (0..<dimensions).map { seed * 10 + Float($0) + 1 }
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reads every committed slot's vector back out of a generation.
    static func vectors(in generation: DatabaseGeneration) throws -> [[Float]] {
        let count = generation.slotMap.count
        guard count > 0 else { return [] }
        return try generation.vectorStore.withVectorMatrix { base in
            (0..<count).map { slot in
                Array(UnsafeBufferPointer(start: base.advanced(by: slot * dimensions), count: dimensions))
            }
        }
    }

    /// Runs a compactor over `source` into a fresh parent directory.
    static func compact(_ source: DatabaseGeneration) throws -> (generation: DatabaseGeneration, destination: URL) {
        let destination = try temporaryDirectory()
        let plan = CompactionPlan(documentRanges: source.documentLog.ranges)
        let slots = Array(source.slotMap[..<source.slotMap.count])

        let compactor = Compactor(plan: plan,
                                  slots: slots,
                                  vectorFile: source.vectorStore.url,
                                  destinationParent: destination,
                                  generation: source.generation + 1,
                                  dimensions: dimensions)

        return (try compactor.run(), destination)
    }

    // MARK: - Identity

    @Test("Compacting an index with nothing deleted changes nothing.")
    func testCompactingALiveIndexIsTheIdentity() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let first = UUID(), second = UUID()
        try source.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                          documentUUID: first, documentID: 1)
        try source.submit(embeddings: [Self.vector(3)], ids: [12],
                          documentUUID: second, documentID: 2)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.slotMap.count == 3)
        #expect(try Self.vectors(in: compacted) == Self.vectors(in: source))
        #expect(try compacted.documentLog.range(for: first) == 0..<2)
        #expect(try compacted.documentLog.range(for: second) == 2..<3)
    }

    @Test("Every vector survives the copy intact.")
    func testVectorsAreCopiedIntact() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let written = [Self.vector(1), Self.vector(2), Self.vector(3)]
        try source.submit(embeddings: written, ids: [10, 11, 12], documentUUID: UUID(), documentID: 1)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        let readBack = try Self.vectors(in: compacted)
        try #require(readBack.count == written.count)

        // `UnsafeRawBufferPointer(start:count:)` counts BYTES. Sizing that block in Floats copies a
        // quarter of each document and leaves the rest zero-filled.
        for (index, expected) in written.enumerated() {
            #expect(readBack[index] == expected, "vector \(index): got \(readBack[index])")
        }
    }

    @Test("Piece IDs follow their vectors into the new slots.")
    func testPieceIDsAreCarriedAcross() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        try source.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [500, 501],
                          documentUUID: UUID(), documentID: 1)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.slotMap[0] == 500)
        #expect(compacted.slotMap[1] == 501)
    }

    @Test("Every document keeps its SQLite rowid through the rewrite.")
    func testDocumentIDsSurvive() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let uuid = UUID()
        try source.submit(embeddings: [Self.vector(1)], ids: [10], documentUUID: uuid, documentID: 4242)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.documentLog.ranges[uuid]?.id == 4242)
    }

    // MARK: - Reclaiming

    @Test("A deleted document's slots do not survive compaction.")
    func testDeletedDocumentsAreDropped() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let doomed = UUID(), survivor = UUID()
        try source.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                          documentUUID: doomed, documentID: 1)
        try source.submit(embeddings: [Self.vector(3)], ids: [12],
                          documentUUID: survivor, documentID: 2)
        try source.delete(documentUUID: doomed, documentID: 1)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.slotMap.count == 1, "two dead slots reclaimed, one live slot kept")
        #expect(compacted.slotMap[0] == 12)
        #expect(try Self.vectors(in: compacted) == [Self.vector(3)])
        #expect(try compacted.documentLog.range(for: survivor) == 0..<1)
        #expect(throws: DocumentMapError.rangeDoesNotExist(uuid: doomed)) {
            _ = try compacted.documentLog.range(for: doomed)
        }
    }

    @Test("Survivors are renumbered into a contiguous run with no holes.")
    func testSurvivorsAreRenumberedContiguously() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        var survivors: [UUID] = []
        for index in 0..<6 {
            let uuid = UUID()
            try source.submit(embeddings: [Self.vector(Float(index)), Self.vector(Float(index) + 0.5)],
                              ids: [UInt64(index * 2), UInt64(index * 2 + 1)],
                              documentUUID: uuid, documentID: UInt64(index))
            // Delete every other one, so the survivors start scattered across the old file.
            if index.isMultiple(of: 2) {
                survivors.append(uuid)
            } else {
                try source.delete(documentUUID: uuid, documentID: Int64(index))
            }
        }

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.slotMap.count == 6, "3 survivors x 2 slots")

        var expectedStart = 0
        for uuid in survivors {
            let range = try compacted.documentLog.range(for: uuid)
            #expect(range.lowerBound == expectedStart, "a hole here would leave an unowned slot")
            expectedStart = range.upperBound
        }
        #expect(expectedStart == compacted.slotMap.count)
    }

    @Test("The compacted slot count matches what the plan predicted.")
    func testCompactedSlotCountMatchesThePlan() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let doomed = UUID()
        try source.submit(embeddings: [Self.vector(1), Self.vector(2), Self.vector(3)],
                          ids: [10, 11, 12], documentUUID: doomed, documentID: 1)
        try source.submit(embeddings: [Self.vector(4)], ids: [13], documentUUID: UUID(), documentID: 2)
        try source.delete(documentUUID: doomed, documentID: 1)

        let plan = CompactionPlan(documentRanges: source.documentLog.ranges)
        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(plan.slotCount == 1)
        #expect(compacted.slotMap.count == plan.slotCount)
    }

    @Test("The compacted vector file is sized for the survivors, not the source's slot count.")
    func testCompactedFileIsNotOversized() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        var doomed: [UUID] = []
        for index in 0..<10 {
            let uuid = UUID()
            try source.submit(embeddings: [Self.vector(Float(index))], ids: [UInt64(index)],
                              documentUUID: uuid, documentID: UInt64(index))
            if index > 0 { doomed.append(uuid) }
        }
        for (offset, uuid) in doomed.enumerated() {
            try source.delete(documentUUID: uuid, documentID: Int64(offset + 1))
        }

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(compacted.slotMap.count == 1)
        #expect(compacted.vectorStore.capacity == 1,
                "reserving for the source's slot count leaves the reclaimed space still allocated")
    }

    // MARK: - Edge cases

    @Test("A document that owns no slots survives with an empty range.")
    func testImageOnlyDocumentSurvives() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let imageOnly = UUID(), text = UUID()
        try source.submit(embeddings: [], ids: [], documentUUID: imageOnly, documentID: 1)
        try source.submit(embeddings: [Self.vector(1)], ids: [10], documentUUID: text, documentID: 2)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(try compacted.documentLog.range(for: imageOnly).isEmpty,
                "dropping it would make reconcile re-index it on every open, forever")
        #expect(try compacted.documentLog.range(for: text) == 0..<1)
    }

    @Test("A plan with no moves produces an empty generation.")
    func testEmptyPlanProducesAnEmptyGeneration() throws {
        // An index whose documents have all been deleted has the most to reclaim, so refusing to
        // compact it would strand the entire vector file. The plan is empty, the copy loop does
        // nothing, and the new generation is a valid empty one.
        let destination = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let compactor = Compactor(plan: CompactionPlan(documentRanges: [:]),
                                  slots: [],
                                  vectorFile: source.vectorStore.url,
                                  destinationParent: destination,
                                  generation: 1,
                                  dimensions: Self.dimensions)

        let compacted = try compactor.run()

        #expect(compacted.slotMap.count == 0)
        #expect(compacted.documentLog.ranges.isEmpty)
        #expect(compacted.vectorStore.capacity == 0, "nothing live, so nothing reserved")
    }

    @Test("Deleting every document reclaims the whole vector file.")
    func testCompactingAFullyDeletedIndex() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        var documents: [UUID] = []
        for index in 0..<4 {
            let uuid = UUID()
            documents.append(uuid)
            try source.submit(embeddings: [Self.vector(Float(index))], ids: [UInt64(index)],
                              documentUUID: uuid, documentID: UInt64(index))
        }
        for (index, uuid) in documents.enumerated() {
            try source.delete(documentUUID: uuid, documentID: Int64(index))
        }

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(source.slotMap.count == 4, "the source still holds four dead slots")
        #expect(compacted.slotMap.count == 0, "all four reclaimed")
        #expect(compacted.vectorStore.capacity == 0)
    }

    // MARK: - Durability

    @Test("The compacted generation reloads from disk with the same contents.")
    func testCompactedGenerationSurvivesAReload() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.dimensions))

        let doomed = UUID(), survivor = UUID()
        try source.submit(embeddings: [Self.vector(1)], ids: [10], documentUUID: doomed, documentID: 1)
        try source.submit(embeddings: [Self.vector(2), Self.vector(3)], ids: [11, 12],
                          documentUUID: survivor, documentID: 2)
        try source.delete(documentUUID: doomed, documentID: 1)

        let (compacted, destination) = try Self.compact(source)
        defer { try? FileManager.default.removeItem(at: destination) }
        try compacted.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: compacted.generation, in: destination)

        #expect(reloaded.slotMap.count == 2)
        #expect(reloaded.slotMap[0] == 11)
        #expect(reloaded.slotMap[1] == 12)
        #expect(try reloaded.documentLog.range(for: survivor) == 0..<2)
        #expect(try Self.vectors(in: reloaded) == [Self.vector(2), Self.vector(3)])
    }
}

// MARK: - AccelerateIndex.compact()

struct AccelerateIndexCompactionTests {

    final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int
        init(dimension: Int) { self.dimension = dimension }
        func embed(content: String) async throws -> [Double] {
            fatalError("compaction never embeds")
        }
    }

    static let dimensions = 4

    static func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[axis] = 1
        return v
    }

    static func document(id: Int64, pieces: [(pieceID: Int64, embedding: [Float])]) -> IrisDocument {
        var document = IrisDocument(uuid: UUID(), title: "t", description: "d", pieces: pieces.map {
            var piece = DocumentPiece(
                content: .text(content: "piece \($0.pieceID)",
                               location: DocumentLocation(sequenceIndex: 0, documentLength: 1,
                                                          anchor: .text(characterRange: 0..<1))),
                embeddings: $0.embedding,
                parentID: id)
            piece.id = $0.pieceID
            return piece
        })
        document.id = id
        return document
    }

    static func makeIndex() throws -> (index: AccelerateIndex, directory: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try AccelerateIndex(indexLocation: dir,
                                    embeddingProvider: StubEmbedder(dimension: dimensions)), dir)
    }

    @Test("Compaction advances the generation and repoints `current` at it.")
    func testCompactionSwapsTheGeneration() async throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: Self.document(id: 2, pieces: [(11, Self.basis(1))]))
        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [])

        try await index.compact()

        #expect(DatabaseGeneration.getCurrentDatabase(in: dir) == 1,
                "`current` must name the compacted generation, not the one it replaced")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "gen-0").path(percentEncoded: false)),
                "the superseded generation is deleted once `current` no longer names it")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "gen-1").path(percentEncoded: false)))
    }

    @Test("Search returns the same results before and after compaction.")
    func testSearchIsUnchangedByCompaction() async throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: Self.document(id: 2, pieces: [(20, Self.basis(1))]))
        try index.addDocument(document: Self.document(id: 3, pieces: [(30, Self.basis(2))]))
        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [])

        let before = try index.search(query: Self.basis(1), kItems: 5)
        try await index.compact()
        let after = try index.search(query: Self.basis(1), kItems: 5)

        #expect(before.map(\.id) == after.map(\.id), "piece rowids must survive renumbering")
        for (a, b) in zip(before, after) {
            #expect(abs(a.distance - b.distance) < 1e-6)
        }
    }

    @Test("A document deleted before compaction stays gone afterwards.")
    func testDeletedDocumentDoesNotReturn() async throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: Self.document(id: 2, pieces: [(20, Self.basis(1))]))
        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [])

        try await index.compact()

        let results = try index.search(query: Self.basis(0), kItems: 5)
        #expect(!results.contains { $0.id == 10 })
    }

    @Test("The index keeps working after compaction.")
    func testIndexAcceptsWritesAfterCompaction() async throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: Self.document(id: 2, pieces: [(20, Self.basis(1))]))
        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [])

        try await index.compact()

        // Slot numbering restarted during compaction; a stale durable count would make this append
        // land on top of a live slot.
        try index.addDocument(document: Self.document(id: 3, pieces: [(30, Self.basis(2))]))

        let results = try index.search(query: Self.basis(2), kItems: 1)
        #expect(results.first?.id == 30)
    }

    @Test("A compacted index reopens from disk with the compacted contents.")
    func testCompactedIndexReopens() async throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: Self.document(id: 2, pieces: [(20, Self.basis(1))]))
        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [])

        try await index.compact()

        let reopened = try AccelerateIndex(indexLocation: dir,
                                           embeddingProvider: StubEmbedder(dimension: Self.dimensions))
        let results = try reopened.search(query: Self.basis(1), kItems: 5)

        #expect(results.map(\.id) == [20], "got \(results.map(\.id))")
    }
}
