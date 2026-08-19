//
//  AccelerateSearchTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/19/26.
//

import Foundation
import Testing
@testable import IrisSearch
@testable import IrisCommon

struct AccelerateSearchTests {

    // MARK: - Fixtures

    /// `AccelerateIndex` only reads `dimension` from its provider — embedding happens upstream in
    /// `IrisDB`, so search never calls `embed`.
    final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int
        init(dimension: Int) { self.dimension = dimension }
        func embed(content: String) async throws -> [Double] {
            fatalError("search must never embed — it is handed an already-embedded query")
        }
    }

    static let dimensions = 4

    /// One-hot unit vectors, so an inner product is 1.0 against itself and 0.0 against any other.
    /// That makes every expected score exact rather than approximate.
    static func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[axis] = 1
        return v
    }

    /// A document whose pieces already carry the rowids SQLite would have assigned.
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

    static func makeIndex(dimensions: Int = dimensions) throws -> (index: AccelerateIndex, directory: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try AccelerateIndex(indexLocation: dir, embeddingProvider: StubEmbedder(dimension: dimensions))
        return (index, dir)
    }

    // MARK: - Empty and degenerate inputs

    @Test func testSearchOnAnEmptyIndexReturnsNothing() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try index.search(query: Self.basis(0), kItems: 10).isEmpty)
    }

    @Test func testSearchWithZeroKReturnsNothing() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [(10, Self.basis(0))]))
        #expect(try index.search(query: Self.basis(0), kItems: 0).isEmpty)
    }

    @Test func testQueryOfTheWrongDimensionThrows() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [(10, Self.basis(0))]))

        #expect(throws: AccelerateIndexError.self) {
            _ = try index.search(query: [1, 0], kItems: 5)
        }
    }

    // MARK: - Ranking

    @Test func testExactMatchScoresOneAndRanksFirst() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [
            (10, Self.basis(0)), (11, Self.basis(1)), (12, Self.basis(2)),
        ]))

        let results = try index.search(query: Self.basis(1), kItems: 3)

        #expect(results.count == 3)
        #expect(abs(results[0].distance - 1.0) < 1e-5, "an identical unit vector scores exactly 1")
        #expect(abs(results[1].distance) < 1e-5, "orthogonal vectors score 0")
    }

    @Test func testResultsAreOrderedByDescendingSimilarity() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Deliberately not in score order, so a stable sort would not accidentally pass.
        try index.addDocument(document: Self.document(id: 1, pieces: [
            (10, [0.6, 0.8, 0, 0]),
            (11, [1.0, 0.0, 0, 0]),
            (12, [0.0, 1.0, 0, 0]),
        ]))

        let results = try index.search(query: Self.basis(0), kItems: 3)
        let scores = results.map(\.distance)

        #expect(scores == scores.sorted(by: >), "got \(scores)")
    }

    @Test func testKLimitsTheNumberOfResults() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [
            (10, Self.basis(0)), (11, Self.basis(1)), (12, Self.basis(2)), (13, Self.basis(3)),
        ]))

        #expect(try index.search(query: Self.basis(0), kItems: 2).count == 2)
    }

    @Test func testKLargerThanTheCorpusReturnsEverything() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [(10, Self.basis(0)), (11, Self.basis(1))]))

        #expect(try index.search(query: Self.basis(0), kItems: 100).count == 2)
    }

    // MARK: - Identity of the returned id

    @Test func testResultsReturnPieceRowidsNotSlotNumbers() throws {
        // IrisDB uses the returned id to fetch the DocumentPiece row, so it must be the SQLite
        // rowid the slot map stores — not the slot's position in the matrix. They coincide only
        // when the first document happens to start at slot 0 with rowid 0.
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [
            (500, Self.basis(0)), (501, Self.basis(1)),
        ]))

        let results = try index.search(query: Self.basis(0), kItems: 1)

        #expect(results.first?.id == 500,
                "expected the piece rowid 500, got \(results.first?.id ?? -1)")
    }

    @Test func testResultIDsSurviveAcrossDocuments() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [(700, Self.basis(0))]))
        try index.addDocument(document: Self.document(id: 2, pieces: [(800, Self.basis(1))]))

        let results = try index.search(query: Self.basis(1), kItems: 1)
        #expect(results.first?.id == 800)
    }

    // MARK: - Deletion

    @Test func testDeletedPiecesDoNotAppearInResults() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doomed = Self.document(id: 1, pieces: [(10, Self.basis(0))])
        let survivor = Self.document(id: 2, pieces: [(11, Self.basis(1))])
        try index.addDocument(document: doomed)
        try index.addDocument(document: survivor)

        try index.removeDocument(documentUUID: doomed.uuid, documentID: 1, pieceIDs: [10])

        let results = try index.search(query: Self.basis(0), kItems: 10)
        #expect(!results.contains { $0.id == 10 }, "a tombstoned slot must never reach the results")
    }

    @Test func testDeletingAllButOneStillReturnsTheOne() throws {
        // The filter-after-selection trap: if tombstones are removed from the finished top-k
        // rather than skipped during selection, the k best are all dead, they get dropped, and
        // there is no k+1 to fall back on — so the query returns nothing.
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        var documents: [IrisDocument] = []
        for axis in 0..<4 {
            let document = Self.document(id: Int64(axis + 1), pieces: [(Int64(10 + axis), Self.basis(axis))])
            documents.append(document)
            try index.addDocument(document: document)
        }

        for document in documents.dropLast() {
            try index.removeDocument(documentUUID: document.uuid,
                                     documentID: document.id!, pieceIDs: [])
        }

        let results = try index.search(query: Self.basis(3), kItems: 3)
        #expect(results.count == 1, "one document survives, so one result must come back")
        #expect(results.first?.id == 13)
    }

    // MARK: - search(within:)

    @Test func testSearchWithinRestrictsToOneDocument() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Self.document(id: 1, pieces: [(10, Self.basis(0)), (11, Self.basis(1))])
        let second = Self.document(id: 2, pieces: [(20, Self.basis(2)), (21, Self.basis(3))])
        try index.addDocument(document: first)
        try index.addDocument(document: second)

        let results = try index.search(query: Self.basis(0), kItems: 10, collection: second.uuid)

        #expect(results.count == 2, "only the second document's two pieces are in range")
        #expect(results.allSatisfy { $0.id == 20 || $0.id == 21 },
                "got \(results.map(\.id)) — the first document's slots leaked in")
    }

    @Test func testSearchWithinScoresTheCorrectRows() throws {
        // The scan must offset the matrix base by the range's lower bound. Without it the second
        // document's search silently scores the FIRST document's vectors.
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Self.document(id: 1, pieces: [(10, Self.basis(0)), (11, Self.basis(0))])
        let second = Self.document(id: 2, pieces: [(20, Self.basis(3))])
        try index.addDocument(document: first)
        try index.addDocument(document: second)

        // basis(3) is orthogonal to everything in `first` and identical to the one piece in `second`.
        let results = try index.search(query: Self.basis(3), kItems: 5, collection: second.uuid)

        #expect(results.count == 1)
        #expect(abs((results.first?.distance ?? 0) - 1.0) < 1e-5,
                "scored \(results.first?.distance ?? 0) — the wrong rows were read")
    }

    @Test func testSearchWithinAnUnknownDocumentThrows() throws {
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [(10, Self.basis(0))]))

        #expect(throws: DocumentMapError.self) {
            _ = try index.search(query: Self.basis(0), kItems: 5, collection: UUID())
        }
    }

    @Test func testSearchWithinADocumentWithNoEmbeddedPiecesReturnsNothing() throws {
        // An image-only document owns an empty slot range but is still live.
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageOnly = Self.document(id: 1, pieces: [])
        try index.addDocument(document: imageOnly)

        #expect(try index.search(query: Self.basis(0), kItems: 5, collection: imageOnly.uuid).isEmpty)
    }

    // MARK: - Normalisation

    @Test func testAnUnnormalisedQueryScoresTheSameAsANormalisedOne() throws {
        // `search` L2-normalises before scoring, so magnitude must not change the ranking.
        let (index, dir) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        try index.addDocument(document: Self.document(id: 1, pieces: [
            (10, Self.basis(0)), (11, Self.basis(1)),
        ]))

        let unit = try index.search(query: [1, 0, 0, 0], kItems: 2)
        let scaled = try index.search(query: [7, 0, 0, 0], kItems: 2)

        #expect(unit.map(\.id) == scaled.map(\.id))
        for (a, b) in zip(unit, scaled) {
            #expect(abs(a.distance - b.distance) < 1e-5)
        }
    }
}
