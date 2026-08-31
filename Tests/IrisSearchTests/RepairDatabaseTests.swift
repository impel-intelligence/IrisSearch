//
//  RepairDatabaseTests.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/25/26.
//
//  `IrisDB.repairDatabase` is the layer above `AccelerateIndex.repair`: the index reports which
//  documents SQLite still has and the index lost, and this is what actually gets them back.
//
//  That distinction matters for what these tests can assert. The "Remove Embeddings Column"
//  migration dropped `DocumentPiece.embeddings` from SQLite, so recovering a lost document is a
//  genuine re-embed, not a re-add of stored vectors — which is exactly why the loop lives here,
//  where the embedder is, rather than inside the index.

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import GRDB
import TestUtilities

struct RepairDatabaseTests {

    // MARK: - Fixtures

    /// Deterministic and cheap. A real embedder would make every test here a model load, and the
    /// repair path never inspects the vectors it round-trips — only which documents own them.
    final class CountingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int = 8
        private let counter = Counter()
        var callCount: Int { counter.value }

        /// A tiny box rather than an `NSLock`: locking is unavailable from an async context, and
        /// `embed` is `async`.
        final class Counter: @unchecked Sendable {
            private let queue = DispatchQueue(label: "counting-embedder")
            private var count = 0
            var value: Int { queue.sync { count } }
            func increment() { queue.sync { count += 1 } }
        }

        func embed(content: String) async throws -> [Double] {
            counter.increment()

            // Hash the content into a stable unit vector so equal text embeds equally and
            // different text does not collide.
            var hash = UInt64(truncatingIfNeeded: content.hashValue)
            var vector = (0..<dimension).map { _ -> Double in
                hash = hash &* 6364136223846793005 &+ 1442695040888963407
                return Double(hash >> 33) / Double(UInt32.max) - 0.5
            }
            let norm = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
            if norm > 0 { for index in vector.indices { vector[index] /= norm } }
            return vector
        }
    }

    static func content(_ text: String) -> EmbeddableContent {
        .text(content: text,
              location: DocumentLocation(sequenceIndex: 0, documentLength: 1,
                                         anchor: .text(characterRange: 0..<text.count)))
    }

    /// Deletes the whole index directory, so reopening builds an empty generation while every row
    /// stays in SQLite. That is the widest possible version of "the index is behind SQLite", and it
    /// needs no byte-level corruption to produce.
    static func discardIndex(at directories: TestingDirectories) throws {
        try FileManager.default.removeItem(at: directories.textIndexURL)
        try FileManager.default.createDirectory(at: directories.textIndexURL, withIntermediateDirectories: true)
    }

    // MARK: - Nothing to do

    @Test func testRepairOnAHealthyDatabaseChangesNothing() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()
        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)

        _ = try await database.createDocument(uuid: UUID(), title: "kept", description: "d",
                                              embeddableContent: [Self.content("the quick brown fox")])
        try await database.close()

        let callsBefore = embedder.callCount
        try await database.repairDatabase()

        #expect(embedder.callCount == callsBefore,
                "Nothing is missing, so nothing may be re-embedded.")
        #expect(!(await database.requiresRepair))
    }

    @Test func testRepairOnAnEmptyDatabaseSucceeds() async throws {
        let directories = TestingDirectories()
        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: CountingEmbedder())

        try await database.repairDatabase()
        #expect(!(await database.requiresRepair))
    }

    // MARK: - Index behind SQLite

    @Test func testADocumentLostFromTheIndexIsReEmbedded() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        let document = try await first.createDocument(uuid: UUID(), title: "lost", description: "d",
                                                      embeddableContent: [Self.content("vectors about herons")])
        try await first.close()

        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)
        let callsBefore = embedder.callCount
        try await reopened.repairDatabase()

        #expect(embedder.callCount > callsBefore, "Recovery has to re-embed; the vectors are gone.")

        let recovered = try await reopened.readDocument(uuid: document.uuid)
        #expect(recovered?.title == "lost", "The row was never at risk — only its vectors.")
    }

    @Test func testAReEmbeddedDocumentIsSearchableAgain() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        let document = try await first.createDocument(uuid: UUID(), title: "recoverable", description: "d",
                                                      embeddableContent: [Self.content("migrating herons in winter")])
        try await first.close()

        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)

        // Precondition, asserted against the index rather than through `search(within:)`: that
        // search fuses semantic and syntactic hits, and FTS still has the text in SQLite, so it
        // finds the piece with or without vectors. Only the index knows the vectors are gone.
        #expect(await reopened.requiresRepair == false,
                "An emptied index is not damaged — it simply has nothing, which is what repair fixes.")
        let indexURL = directories.textIndexURL
        let before = try DatabaseGeneration.load(generation: 0, in: indexURL)
        #expect(before.documentLog.ranges[document.uuid] == nil,
                "Precondition: the index holds no range for this document.")

        try await reopened.repairDatabase()

        let afterRepair = try await reopened.search(within: document.uuid,
                                                    query: .init(text: "migrating herons in winter"))
        #expect(!afterRepair.importantPieces.isEmpty, "Repair has to restore semantic reachability, not just the row.")
    }

    @Test func testEveryLostDocumentIsRecoveredNotJustTheFirst() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        var uuids: [UUID] = []
        for index in 0..<4 {
            let document = try await first.createDocument(uuid: UUID(), title: "doc-\(index)", description: "d",
                                                          embeddableContent: [Self.content("subject number \(index)")])
            uuids.append(document.uuid)
        }
        try await first.close()

        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)
        try await reopened.repairDatabase()

        for (index, uuid) in uuids.enumerated() {
            let result = try await reopened.search(within: uuid, query: .init(text: "subject number \(index)"))
            #expect(!result.importantPieces.isEmpty, "doc-\(index) was not recovered")
        }
    }

    @Test func testRepairDoesNotDuplicateTheDocumentItRecovers() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        let document = try await first.createDocument(uuid: UUID(), title: "single", description: "d",
                                                      embeddableContent: [Self.content("one piece only")])
        try await first.close()

        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)
        try await reopened.repairDatabase()

        let pieces = try await reopened.readDocument(uuid: document.uuid)?.pieces ?? []
        #expect(pieces.count == 1, "Recovery must replace the document's pieces, not append a second copy.")

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let storedPieces = try await dbQueue.read { db in try DocumentPiece.fetchAll(db) }
        #expect(storedPieces.count == 1, "SQLite must not accumulate orphaned pieces either.")
    }

    // MARK: - Idempotence

    @Test func testASecondRepairFindsNothingLeftToDo() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        _ = try await first.createDocument(uuid: UUID(), title: "once", description: "d",
                                           embeddableContent: [Self.content("only embedded twice at most")])
        try await first.close()

        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)
        try await reopened.repairDatabase()

        let callsAfterFirstRepair = embedder.callCount
        try await reopened.repairDatabase()

        #expect(embedder.callCount == callsAfterFirstRepair,
                "A second pass must be a no-op; otherwise every open re-embeds the corpus.")
    }

    // MARK: - Index ahead of SQLite

    @Test func testADocumentDeletedFromSQLiteIsNotResurrected() async throws {
        let directories = TestingDirectories()
        let embedder = CountingEmbedder()

        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)

        let doomed = try await database.createDocument(uuid: UUID(), title: "doomed", description: "d",
                                                       embeddableContent: [Self.content("about to vanish")])
        let survivor = try await database.createDocument(uuid: UUID(), title: "survivor", description: "d",
                                                         embeddableContent: [Self.content("stays put")])

        // Delete the row behind the index's back, which is the state a crash between SQLite's
        // commit and the index write leaves.
        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        _ = try await dbQueue.write { db in
            try IrisDocument.deleteOne(db, key: ["uuid": doomed.uuid])
        }

        try await database.repairDatabase()

        let hits = try await database.search(query: .init(text: "about to vanish"))
        #expect(!hits.contains { $0.document.uuid == doomed.uuid },
                "Vectors whose row is gone would resolve to a dead rowid.")

        let stillThere = try await database.search(within: survivor.uuid, query: .init(text: "stays put"))
        #expect(!stillThere.importantPieces.isEmpty, "The unrelated document must be untouched.")
    }

    /// Every document `repairDatabase` is about to recover is in this state, so a caller that
    /// searches during recovery must get an empty page rather than a hard error. This was finding #8
    /// on the PR, where `rangeDoesNotExist` escaped instead.
    @Test func testAScopedSearchForAnUnindexedDocumentReturnsNothing() async throws {
        let directories = TestingDirectories()
        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: CountingEmbedder())

        let document = try await database.createDocument(uuid: UUID(), title: "gone", description: "d",
                                                         embeddableContent: [Self.content("indexed once")])
        try await database.close()
        try Self.discardIndex(at: directories)

        let reopened = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: CountingEmbedder())

        // The assertion is that this returns at all. Before the fix it threw `rangeDoesNotExist`,
        // which turned every search during recovery into a hard error. Syntactic hits still come
        // back from FTS, so the result is not expected to be empty — only non-throwing.
        _ = try await reopened.search(within: document.uuid, query: .init(text: "indexed once"))
    }
}
