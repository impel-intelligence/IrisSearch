//
//  DatabaseUpgradeTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-13.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import GRDB
import TestUtilities

/// Validates that a real on-disk database created under IrisSearch 1.0.2 (before `DocumentPiece` had any
/// location columns) upgrades cleanly when opened by the current `IrisDB`, which adds the "Add Document
/// Locations" migration on top. Instead of checking out the old tag, this pins the exact 1.0.2 schema
/// (`git show 1.0.2:Sources/IrisSearch/IrisDB.swift`) as a standalone legacy migrator and seeds rows with raw
/// SQL, since the old `EmbeddableContent`/`DocumentPiece` Swift API no longer exists in this source tree.
class IrisDB_DatabaseUpgradeTests {

    /// Exactly the "Create Documents Table" migration registered by IrisSearch 1.0.2, before `document_pieces`
    /// had `sequenceIndex`, `documentLength`, or `documentAnchor` columns. Intentionally pinned with literal
    /// table/column names rather than referencing current model types, so this stays a faithful snapshot of
    /// the old on-disk schema even if those types are renamed later.
    private func makeLegacyMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("Create Documents Table") { db in
            try db.create(table: "documents") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("uuid", .blob).unique().notNull()
                table.column("title", .text).unique().notNull()
                table.column("description", .text).notNull()
            }

            try db.create(virtualTable: "documents_ft", using: FTS5()) { table in
                table.tokenizer = .porter()
                table.synchronize(withTable: "documents")
                table.column("id")
                table.column("title")
                table.column("description")
            }

            try db.create(table: "document_pieces") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("contentType", .integer).notNull()
                table.column("textContent", .text)
                table.column("dataContent", .blob)
                table.column("embeddings", .blob).notNull()

                table.column("parentID", .integer).notNull()
                table.foreignKey(["parentID"], references: "documents", onDelete: .cascade)
            }

            try db.create(virtualTable: "document_pieces_ft", using: FTS5()) { table in
                table.tokenizer = .porter()
                table.synchronize(withTable: "document_pieces")
                table.column("id")
                table.column("parentID")
                table.column("textContent")
            }
        }

        return migrator
    }

    /// Creates the `.irisdb` bundle on disk, applies the legacy 1.0.2 schema, and inserts one legacy document
    /// with one text piece using raw SQL matching that schema exactly (no location columns).
    @discardableResult
    private func seedLegacyDatabase(
        at directories: TestingDirectories,
        title: String,
        description: String,
        content: String,
        embeddings: [Float]
    ) throws -> UUID {
        try FileManager.default.createDirectory(at: directories.bundleURL, withIntermediateDirectories: true)

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        try makeLegacyMigrator().migrate(dbQueue)

        let uuid = UUID()
        let embeddingsData = embeddings.withUnsafeBytes { Data($0) }

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO documents (uuid, title, description) VALUES (?, ?, ?)",
                arguments: [uuid, title, description]
            )
            let documentID = db.lastInsertedRowID

            try db.execute(
                sql: "INSERT INTO document_pieces (contentType, textContent, dataContent, embeddings, parentID) VALUES (?, ?, ?, ?, ?)",
                arguments: [EmbeddableContent.ContentType.text.rawValue, content, nil, embeddingsData, documentID]
            )
        }

        return uuid
    }

    @Test func upgradingLegacyDatabasePreservesExistingDocuments() async throws {
        let directories = TestingDirectories()

        let legacyContent = "Legacy content created before document locations existed."
        let legacyUUID = try seedLegacyDatabase(
            at: directories,
            title: "Legacy Document",
            description: "Created under the pre-2.0 schema",
            content: legacyContent,
            embeddings: [0.1, 0.2, 0.3]
        )

        // Opening with the current IrisDB should run "Add Document Locations" on top of the legacy schema
        // without error, since "Create Documents Table" is already recorded as applied by name.
        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let upgradedDocument = try await database.readDocument(uuid: legacyUUID)
        #expect(upgradedDocument != nil, "The document created under the old schema should still be readable after the upgrade.")
        #expect(upgradedDocument?.pieces.count == 1)

        let legacyPiece = upgradedDocument?.pieces.first
        #expect(legacyPiece?.text == legacyContent, "Legacy content should be unaffected by the schema upgrade.")

        // The new location columns are NULL for pre-existing rows, so they should load with the documented defaults.
        let location = legacyPiece?.content.location
        #expect(location?.sequenceIndex == 0, "Legacy pieces should default to sequenceIndex 0.")
        #expect(location?.documentLength == 1, "Legacy pieces should default to documentLength 1.")
        if case .text(let range) = location?.anchor {
            #expect(range == 0..<legacyContent.count, "Legacy pieces should default to a text anchor spanning their entire content.")
        } else {
            Issue.record("Expected legacy piece to default to a .text anchor, got \(String(describing: location?.anchor))")
        }
    }

    @Test func newDocumentsAfterUpgradeStoreRealLocationDataAlongsideLegacyRows() async throws {
        let directories = TestingDirectories()

        let legacyContent = "Legacy content that should be untouched by later writes."
        let legacyUUID = try seedLegacyDatabase(
            at: directories,
            title: "Legacy Document",
            description: "Created under the pre-2.0 schema",
            content: legacyContent,
            embeddings: [0.4, 0.5]
        )

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let newContent = "Brand new content written after the upgrade."
        let newUUID = UUID()
        let newLocation = DocumentLocation(sequenceIndex: 2, documentLength: 4, anchor: .pdf(page: 1, characterRange: 0..<newContent.count))

        try await database.createDocument(
            uuid: newUUID, title: "New Document", description: "desc",
            embeddableContent: [.text(content: newContent, location: newLocation)]
        )

        let newDocument = try await database.readDocument(uuid: newUUID)
        #expect(newDocument?.pieces.count == 1)

        let newSavedLocation = newDocument?.pieces.first?.content.location
        #expect(newSavedLocation?.sequenceIndex == 2, "Newly written pieces should round-trip their real sequenceIndex.")
        #expect(newSavedLocation?.documentLength == 4, "Newly written pieces should round-trip their real documentLength.")
        if case .pdf(let page, let range) = newSavedLocation?.anchor {
            #expect(page == 1)
            #expect(range == 0..<newContent.count)
        } else {
            Issue.record("Expected new piece to have a .pdf anchor, got \(String(describing: newSavedLocation?.anchor))")
        }

        // The legacy document should remain untouched by the new write.
        let legacyDocument = try await database.readDocument(uuid: legacyUUID)
        #expect(legacyDocument?.pieces.first?.text == legacyContent, "The legacy document's content should be unaffected by later writes.")
    }

    @Test func reopeningUpgradedDatabaseIsIdempotentAndPreservesData() async throws {
        let directories = TestingDirectories()

        let legacyContent = "Legacy content surviving repeated opens."
        let legacyUUID = try seedLegacyDatabase(
            at: directories,
            title: "Legacy Document",
            description: "Created under the pre-2.0 schema",
            content: legacyContent,
            embeddings: [0.6]
        )

        let embedder = try NLEmbedder(language: .english)

        // Open (and upgrade) once.
        _ = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        // Open a second time -- should be a migration no-op and should not disturb existing data.
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let document = try await database.readDocument(uuid: legacyUUID)
        #expect(document?.pieces.first?.text == legacyContent, "Data should survive re-opening an already-upgraded database.")
    }
}
