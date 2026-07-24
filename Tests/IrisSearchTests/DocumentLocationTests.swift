//
//  DocumentLocationTests.swift
//  IrisSearch
//
//  Edited by Claude Sonnet 4.6 (Anthropic) on 2026-07-13
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import GRDB
import TestUtilities
import AppleIntelligenceEmbedder

class IrisDB_DocumentLocationTests {

    private func makeDatabase(directories: TestingDirectories) throws -> IrisDB {
        let embedder = try NLEmbedder(language: .english)
        return try IrisDB(
            databaseLocation: directories.baseURL,
            databaseName: directories.databaseName,
            textEmbedder: embedder
        )
    }

    // MARK: - Text Anchor

    @Test func textAnchorRoundTrips() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let content = "Hello world"
        let range = 0..<content.count
        let location = DocumentLocation(sequenceIndex: 3, documentLength: 1, anchor: .text(characterRange: range))

        try await database.createDocument(
            uuid: UUID(), title: "Text Anchor Doc", description: "desc",
            embeddableContent: [.text(content: content, location: location)]
        )

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in try DocumentPiece.fetchAll(db) }

        #expect(pieces.count == 1)
        let saved = pieces[0].content.location
        #expect(saved.sequenceIndex == 3, "sequenceIndex should round-trip through SQLite.")
        if case .text(let savedRange) = saved.anchor {
            #expect(savedRange == range, "Text characterRange should round-trip through SQLite.")
        } else {
            Issue.record("Expected .text anchor, got \(saved.anchor)")
        }
    }

    // MARK: - PDF Anchor

    @Test func pdfAnchorWithCharacterRangeRoundTrips() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let content = "PDF content"
        let range = 5..<20
        let location = DocumentLocation(sequenceIndex: 1, documentLength: 1, anchor: .pdf(page: 4, characterRange: range))

        try await database.createDocument(
            uuid: UUID(), title: "PDF Anchor Doc", description: "desc",
            embeddableContent: [.text(content: content, location: location)]
        )

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in try DocumentPiece.fetchAll(db) }

        #expect(pieces.count == 1)
        let saved = pieces[0].content.location
        #expect(saved.sequenceIndex == 1, "sequenceIndex should round-trip for PDF anchors.")
        if case .pdf(let page, let savedRange) = saved.anchor {
            #expect(page == 4, "PDF page should round-trip through SQLite.")
            #expect(savedRange == range, "PDF characterRange should round-trip through SQLite.")
        } else {
            Issue.record("Expected .pdf anchor, got \(saved.anchor)")
        }
    }

    @Test func pdfAnchorWithNilCharacterRangeRoundTrips() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let location = DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .pdf(page: 7, characterRange: nil))

        try await database.createDocument(
            uuid: UUID(), title: "PDF Nil Range Doc", description: "desc",
            embeddableContent: [.text(content: "page only content", location: location)]
        )

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in try DocumentPiece.fetchAll(db) }

        #expect(pieces.count == 1)
        if case .pdf(let page, let savedRange) = pieces[0].content.location.anchor {
            #expect(page == 7, "PDF page should round-trip with nil characterRange.")
            #expect(savedRange == nil, "Nil characterRange should remain nil after round-trip.")
        } else {
            Issue.record("Expected .pdf anchor, got \(pieces[0].content.location.anchor)")
        }
    }

    // MARK: - Multiple Locations

    @Test func multipleLocationsStoredIndependently() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let content1 = "First piece"
        let content2 = "Second piece"
        let location1 = DocumentLocation(sequenceIndex: 0, documentLength: 2, anchor: .text(characterRange: 0..<content1.count))
        let location2 = DocumentLocation(sequenceIndex: 1, documentLength: 2, anchor: .pdf(page: 2, characterRange: 10..<30))

        try await database.createDocument(
            uuid: UUID(), title: "Multi Location Doc", description: "desc",
            embeddableContent: [
                .text(content: content1, location: location1),
                .text(content: content2, location: location2)
            ]
        )

        let dbQueue = try DatabaseQueue(path: directories.sqliteURL.path())
        let pieces = try await dbQueue.read { db in
            try DocumentPiece.order(Column("id")).fetchAll(db)
        }

        #expect(pieces.count == 2, "Two embeddable items should produce two document pieces.")

        let saved1 = pieces[0].content.location
        #expect(saved1.sequenceIndex == 0, "First piece should preserve sequenceIndex 0.")
        if case .text(let range) = saved1.anchor {
            #expect(range == 0..<content1.count)
        } else {
            Issue.record("Piece 0: expected .text anchor, got \(saved1.anchor)")
        }

        let saved2 = pieces[1].content.location
        #expect(saved2.sequenceIndex == 1, "Second piece should preserve sequenceIndex 1.")
        if case .pdf(let page, let range) = saved2.anchor {
            #expect(page == 2)
            #expect(range == 10..<30)
        } else {
            Issue.record("Piece 1: expected .pdf anchor, got \(saved2.anchor)")
        }
    }

    // MARK: - IrisDB Read API

    @Test func locationPreservedThroughIrisDBReadDocument() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let uuid = UUID()
        let content = "Readable content"
        let range = 0..<content.count
        let location = DocumentLocation(sequenceIndex: 5, documentLength: 1, anchor: .text(characterRange: range))

        try await database.createDocument(
            uuid: uuid, title: "Readable Doc", description: "desc",
            embeddableContent: [.text(content: content, location: location)]
        )

        let readDoc = try await database.readDocument(uuid: uuid)

        #expect(readDoc != nil)
        #expect(readDoc?.pieces.count == 1)

        let savedLocation = readDoc?.pieces.first?.content.location
        #expect(savedLocation?.sequenceIndex == 5, "sequenceIndex should be preserved through readDocument.")
        if case .text(let savedRange) = savedLocation?.anchor {
            #expect(savedRange == range, "text anchor range should be preserved through readDocument.")
        } else {
            Issue.record("Expected .text anchor via IrisDB.readDocument, got \(String(describing: savedLocation?.anchor))")
        }
    }

    @Test func locationPreservedThroughIrisDBReadDocumentByTitle() async throws {
        let directories = TestingDirectories()
        let database = try makeDatabase(directories: directories)

        let title = "Title Round Trip"
        let content = "Title fetch content"
        let location = DocumentLocation(sequenceIndex: 2, documentLength: 1, anchor: .pdf(page: 3, characterRange: 0..<50))

        try await database.createDocument(
            uuid: UUID(), title: title, description: "desc",
            embeddableContent: [.text(content: content, location: location)]
        )

        let readDoc = try await database.readDocument(title: title)

        #expect(readDoc != nil)
        #expect(readDoc?.pieces.count == 1)

        let savedLocation = readDoc?.pieces.first?.content.location
        #expect(savedLocation?.sequenceIndex == 2, "sequenceIndex should be preserved through readDocument(title:).")
        if case .pdf(let page, let range) = savedLocation?.anchor {
            #expect(page == 3)
            #expect(range == 0..<50)
        } else {
            Issue.record("Expected .pdf anchor via IrisDB.readDocument(title:), got \(String(describing: savedLocation?.anchor))")
        }
    }
}
