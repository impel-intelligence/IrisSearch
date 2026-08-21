//
//  PieceCountCacheTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 2026-08-12.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB
import TestUtilities
import AppleIntelligenceEmbedder

/// Covers ``IrisDB/cachedPieceCount``, the cached `SELECT COUNT(*)` that keeps a full table scan off the
/// corpus-wide search path.
///
/// The cache is invisible to behaviour tests: it only feeds `searchLimit`'s upper clamp, and with a real
/// corpus that clamp is inert because `nItems * 2` is orders of magnitude below the true count. A wrong
/// count therefore produces identical search results at identical speed, and drifts unnoticed. These
/// tests assert it directly against a fresh `DocumentPiece.fetchCount`, which is the only ground truth.
///
/// - Authored by: Claude Opus 5 (Anthropic)
class IrisDB_PieceCountCacheTests {
    /// Counts `document_pieces` rows by opening the database file independently of the ``IrisDB`` actor,
    /// so the assertion never reads through the cache it is trying to validate.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func actualPieceCount(_ directories: TestingDirectories) async throws -> Int {
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        return try await dbQueue.read { db in
            try DocumentPiece.fetchCount(db)
        }
    }

    /// Populates the cache. It is filled lazily by the first corpus-wide search, so nothing else primes it.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func primeCache(_ database: IrisDB) async throws {
        _ = try await database.search(query: .init(text: "content"), nItems: 5)
    }

    @Test func cacheMatchesTheDatabaseAfterEveryMutation() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let first = UUID()
        let second = UUID()

        // Multi-chunk documents are the whole point: a per-document delta and a per-piece delta are
        // indistinguishable when every document holds exactly one piece.
        let firstChunks = ["Alpha content one.", "Alpha content two.", "Alpha content three."]
        let secondChunks = ["Beta content one.", "Beta content two."]

        try await database.createDocument(uuid: first, title: "First", description: "First document", embeddableContent: chunkedEmbeddableContent(firstChunks))
        try await database.createDocument(uuid: second, title: "Second", description: "Second document", embeddableContent: chunkedEmbeddableContent(secondChunks))

        try await primeCache(database)

        var expected = try await actualPieceCount(directories)
        #expect(expected == firstChunks.count + secondChunks.count, "Two documents of 3 and 2 chunks should store 5 pieces.")
        var cached = await database.cachedPieceCount
        #expect(cached == expected, "The first corpus-wide search should have filled the cache with the true count.")

        // Create — the delta is the new document's piece count, not one.
        let thirdChunks = ["Gamma one.", "Gamma two.", "Gamma three.", "Gamma four."]
        try await database.createDocument(uuid: UUID(), title: "Third", description: "Third document", embeddableContent: chunkedEmbeddableContent(thirdChunks))

        expected = try await actualPieceCount(directories)
        cached = await database.cachedPieceCount
        #expect(cached == expected, "Creating a 4-chunk document should move the cache by 4, not by 1.")

        // Update, growing the piece set.
        let grownChunks = ["Alpha one.", "Alpha two.", "Alpha three.", "Alpha four.", "Alpha five.", "Alpha six."]
        try await database.updateDocument(uuid: first, title: "First", description: "First document", embeddableContent: chunkedEmbeddableContent(grownChunks))

        expected = try await actualPieceCount(directories)
        cached = await database.cachedPieceCount
        #expect(cached == expected, "Growing a document from 3 to 6 pieces should move the cache by +3.")

        // Update, shrinking the piece set. The delta has to be signed, not an unconditional increment.
        try await database.updateDocument(uuid: first, title: "First", description: "First document", embeddableContent: chunkedEmbeddableContent(["Alpha only."]))

        expected = try await actualPieceCount(directories)
        cached = await database.cachedPieceCount
        #expect(cached == expected, "Shrinking a document from 6 to 1 piece should move the cache by -5.")

        // Delete — the cascade removes every piece the document owned.
        try await database.deleteDocument(uuid: second)

        expected = try await actualPieceCount(directories)
        cached = await database.cachedPieceCount
        #expect(cached == expected, "Deleting a 2-chunk document should move the cache by -2, not by -1.")
    }

    @Test func deletingAMissingDocumentLeavesTheCacheAlone() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        try await database.createDocument(uuid: UUID(), title: "Present", description: "Present document", embeddableContent: chunkedEmbeddableContent(["Present one.", "Present two."]))

        try await primeCache(database)

        let before = await database.cachedPieceCount
        #expect(before == 2, "The cache should hold the two stored pieces before the no-op delete.")

        // Deletes no rows, so it must not adjust the count.
        try await database.deleteDocument(uuid: UUID())

        let expected = try await actualPieceCount(directories)
        let cached = await database.cachedPieceCount
        #expect(cached == expected, "Deleting a uuid that is not in the database must leave the cached count untouched.")
    }

    @Test func reEmbeddingKeepsTheCacheAccurate() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        try await database.createDocument(uuid: UUID(), title: "First", description: "First document", embeddableContent: chunkedEmbeddableContent(["One.", "Two.", "Three."]))
        try await database.createDocument(uuid: UUID(), title: "Second", description: "Second document", embeddableContent: chunkedEmbeddableContent(["Four.", "Five."]))

        try await primeCache(database)

        // Re-embedding drives every document through `updateDocument` with unchanged content, so the count
        // should not move at all. This is where an unmaintained update path drifts furthest.
        try await database.reEmbedEntireDatabase(progress: Progress())

        let expected = try await actualPieceCount(directories)
        let cached = await database.cachedPieceCount
        #expect(cached == expected, "Re-embedding replaces every piece set with an identical one, so the cached count should be unchanged.")
    }

    @Test func cacheIsPopulatedLazilyRatherThanAtInitialization() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        var cached = await database.cachedPieceCount
        #expect(cached == nil, "A freshly opened database should not have paid for a count yet.")

        try await database.createDocument(uuid: UUID(), title: "Only", description: "Only document", embeddableContent: chunkedEmbeddableContent(["Only one."]))

        // A write before the cache is warm must leave it cold rather than seed it with a partial delta.
        cached = await database.cachedPieceCount
        #expect(cached == nil, "Writing while the cache is unset must not fabricate a count from a delta alone.")

        try await primeCache(database)

        let expected = try await actualPieceCount(directories)
        cached = await database.cachedPieceCount
        #expect(cached == expected, "The first corpus-wide search should fill the cache from a real count.")
    }
}
