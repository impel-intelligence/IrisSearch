//
//  IndexMigrationTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/21/26.
//  Edited by Claude Opus 5 (Anthropic) on 8/21/26.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import TestUtilities
import AppleIntelligenceEmbedder

struct IndexMigrationTests {

    /// Replaces whatever index lives at `textIndexURL` with a FAISS one, so the next `IrisDB` sees
    /// the `.index` file that `needsAccelerateMigration` looks for.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private static func installFaissIndex(at textIndexURL: URL, embedder: EmbeddingProvider) throws {
        try? FileManager.default.removeItem(at: textIndexURL)
        try FileManager.default.createDirectory(at: textIndexURL, withIntermediateDirectories: true)

        let faissIndex = try FaissIndex(indexLocation: textIndexURL, embeddingProvider: embedder)

        // The contents do not matter — migration re-embeds from SQLite, never from here. All this
        // has to do is leave a `.index` file behind so the migration path is taken.
        var piece = DocumentPiece(
            content: .text(content: "stale",
                           location: DocumentLocation(sequenceIndex: 0, documentLength: 1,
                                                      anchor: .text(characterRange: 0..<1))),
            embeddings: [Float](repeating: 1, count: embedder.dimension))
        piece.id = 1
        piece.parentID = 1

        var document = IrisDocument(uuid: UUID(), title: "Stale", description: "Stale", pieces: [piece])
        document.id = 1

        try faissIndex.addDocument(document: document)
    }

    @Test
    func testFaissToAccelerateMigration() async throws {
        let directories = TestingDirectories()
        let embedder = try NLEmbedder(language: .english)

        // --- 1. An existing install: documents in SQLite, indexed however the old build indexed them.
        //
        // Migration walks `IrisDocument.fetchAll` and re-embeds each one, so the documents have to
        // exist in the *database*. Adding them to the FAISS index alone leaves SQLite empty and
        // there is nothing to migrate.
        let titles = ["Hello", "Second", "Third"]
        do {
            let database = try IrisDB(databaseLocation: directories.baseURL,
                                      databaseName: directories.databaseName,
                                      textEmbedder: embedder)
            for title in titles {
                _ = try await database.createDocument(
                    uuid: UUID(),
                    title: title,
                    description: "\(title) description",
                    embeddableContent: [
                        .text(content: "\(title) body text",
                              location: DocumentLocation(sequenceIndex: 0, documentLength: 1,
                                                         anchor: .text(characterRange: 0..<1)))
                    ])
            }
        }

        // --- 2. Downgrade the index on disk to FAISS, as it would be before the update.
        try Self.installFaissIndex(at: directories.textIndexURL, embedder: embedder)

        // --- 3. Reopen. This is the first launch of the new build.
        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)

        try #require(await database.requiresReEmbedOfDatabase)

        let backupDirectory = directories.textIndexURL.appending(path: "backup")
        #expect(FileManager.default.fileExists(atPath: backupDirectory.path(percentEncoded: false)),
                "the FAISS index is moved aside before the Accelerate index takes over")
        #expect(FileManager.default.fileExists(atPath: backupDirectory.appending(path: "global.index").path(percentEncoded: false)),
                "the FAISS index is moved aside before the Accelerate index takes over")

        // --- 4. Migrate.
        let progress = Progress()
        try await database.migrateFromFaissIndex(progress: progress)

        #expect(progress.totalUnitCount == Int64(titles.count))
        #expect(progress.completedUnitCount == Int64(titles.count))

        #expect(!FileManager.default.fileExists(atPath: backupDirectory.path(percentEncoded: false)),
                "the backup is removed once every document has been re-embedded")

        // --- 5. The point of all of it: the documents are findable through the new index.
        let results = try await database.search(query: IrisQuery(text: "Second body text"), nItems: 10)

        #expect(!results.isEmpty, "a migrated document must be searchable, or the re-embed did nothing")
        #expect(results.contains { $0.document.title == "Second" },
                "got \(results.map(\.document.title))")
    }

    @Test("An index that is already Accelerate needs no migration.")
    func testAccelerateIndexDoesNotRequireMigration() async throws {
        let directories = TestingDirectories()
        let embedder = try NLEmbedder(language: .english)

        let first = try IrisDB(databaseLocation: directories.baseURL,
                               databaseName: directories.databaseName,
                               textEmbedder: embedder)
        #expect(await first.requiresReEmbedOfDatabase == false)

        // Reopening an index this build wrote must not look like a FAISS install.
        let second = try IrisDB(databaseLocation: directories.baseURL,
                                databaseName: directories.databaseName,
                                textEmbedder: embedder)
        #expect(await second.requiresReEmbedOfDatabase == false)
    }

    @Test("Migrating an empty database completes without doing anything.")
    func testMigrationOfAnEmptyDatabase() async throws {
        let directories = TestingDirectories()
        let embedder = try NLEmbedder(language: .english)

        // Create the bundle, then downgrade it to FAISS without ever adding a document.
        do {
            _ = try IrisDB(databaseLocation: directories.baseURL,
                           databaseName: directories.databaseName,
                           textEmbedder: embedder)
        }
        try Self.installFaissIndex(at: directories.textIndexURL, embedder: embedder)

        let database = try IrisDB(databaseLocation: directories.baseURL,
                                  databaseName: directories.databaseName,
                                  textEmbedder: embedder)
        try #require(await database.requiresReEmbedOfDatabase)

        let progress = Progress()
        try await database.migrateFromFaissIndex(progress: progress)

        #expect(progress.totalUnitCount == 0)
        #expect(progress.completedUnitCount == 0)

        let backupDirectory = directories.textIndexURL.appending(path: "backup")
        #expect(!FileManager.default.fileExists(atPath: backupDirectory.path(percentEncoded: false)),
                "the backup goes even when there was nothing to re-embed")
    }
}
