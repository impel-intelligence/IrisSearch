//
//  Fiass.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//  Edited by Claude Sonnet 4.6 (Anthropic) on 2026-07-13

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB
import TestUtilities
import AppleIntelligenceEmbedder

class IrisDB_FaissIndexTests {
    @Test func faissIndicesAreCreated() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let content = "Test content"
        let location = DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<content.count))

        _ = try await database.createDocument(uuid: uuid, title: "Test title", description: "Test description", embeddableContent: [.text(content: content, location: location)])
        let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
        let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)

        #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index file should exist.")
        #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true, "The global index file should exist.")
    }

    @Test func faissIndicesAreValid() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let content = "Test content"
        let location = DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<content.count))

        _ = try await database.createDocument(uuid: uuid, title: "Test title", description: "Test description", embeddableContent: [.text(content: content, location: location)])
        let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
        let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)

        #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true)

        // Local index is a flat index, so make sure it loads and holds one vector per chunk.
        let localIndex = try FlatIndex.from(localIndexPath.path())
        #expect(localIndex.count == 1, "The local index should hold one vector for the single-chunk document.")

        #expect(FileManager.default.fileExists(atPath: globalIndexPath.path()) == true)

        // The global index is an IDMap
        let globalIndex = try IDMap.from(globalIndexPath.path())
        #expect(globalIndex.idMap().count == 1, "The global index should hold one vector for the single-chunk document.")
    }

    // Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // IrisDB no longer chunks content itself, so this test supplies multiple pre-chunked pieces directly,
    // the way a Digester now would, instead of relying on IrisDB to split one long string into many.
    @Test func updatingDocumentRefreshesLocalIndex() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let originalContent = "Original Content"
        try await database.createDocument(uuid: uuid, title: "Original", description: originalContent, embeddableContent: [.text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<originalContent.count)))])

        let newChunks = ["Lorem ipsum dolor sit amet.", "Consectetur adipiscing elit.", "Sed do eiusmod tempor incididunt."]
        try await database.updateDocument(uuid: uuid, title: "Updated", description: "Updated content", embeddableContent: chunkedEmbeddableContent(newChunks))

        let localIndexPath = FaissIndex.IndexLocation.document(uuid: uuid).filePath(in: directories.textIndexURL)
        #expect(FileManager.default.fileExists(atPath: localIndexPath.path()) == true, "The local index should still exist after an update.")

        let localIndex = try IDMap.from(localIndexPath.path())
        #expect(localIndex.count == newChunks.count, "The local index should hold one vector per supplied chunk of the new content.")
    }

    // Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // IrisDB no longer chunks content itself, so this test supplies multiple pre-chunked pieces directly.
    @Test func updatingDocumentRebuildsGlobalIndexEntry() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let uuid = UUID()
        let originalContent = "Original Content"
        try await database.createDocument(uuid: uuid, title: "Original", description: originalContent, embeddableContent: [.text(content: originalContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<originalContent.count)))])

        let newChunks = ["Lorem ipsum dolor sit amet.", "Consectetur adipiscing elit.", "Sed do eiusmod tempor incididunt."]
        try await database.updateDocument(uuid: uuid, title: "Updated", description: "Updated content", embeddableContent: chunkedEmbeddableContent(newChunks))

        let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
        let globalIndex = try IDMap.from(globalIndexPath.path())
        let ids = globalIndex.idMap()

        #expect(ids.count == newChunks.count, "The global index should contain exactly one entry per supplied chunk of the updated content, with no stale entries.")
    }

    // Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // Each document below is created with exactly one embeddableContent item, and IrisDB no longer chunks
    // content itself, so each is expected to produce exactly one piece.
    @Test func addingDocumentsAccumulatesInGlobalIndex() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let firstUUID = UUID()
        let secondUUID = UUID()
        let firstContent = "First Document"
        let secondContent = "Second Document"
        let first = try await database.createDocument(uuid: firstUUID, title: "First", description: firstContent, embeddableContent: [.text(content: firstContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<firstContent.count)))])
        let second = try await database.createDocument(uuid: secondUUID, title: "Second", description: secondContent, embeddableContent: [.text(content: secondContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<secondContent.count)))])

        let expectedFirst = 1
        let expectedSecond = 1

        let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
        let globalIndex = try IDMap.from(globalIndexPath.path())
        let ids = globalIndex.idMap()
        let firstID = try #require(first.id)
        let secondID = try #require(second.id)

        #expect(firstID != secondID, "Each document should receive a distinct rowID.")
        #expect(ids.count == expectedFirst + expectedSecond, "The global index should contain entries for both documents.")
        #expect(ids.filter { $0 == Int(firstID) }.count == expectedFirst, "The first document's entries should be present in the global index.")
        #expect(ids.filter { $0 == Int(secondID) }.count == expectedSecond, "The second document's entries should be present in the global index.")
    }

    // Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
    // "Keep" is created with exactly one embeddableContent item, and IrisDB no longer chunks content itself,
    // so it is expected to produce exactly one piece.
    @Test func deletingDocumentRemovesItsEntriesFromGlobalIndex() async throws {
        let directories = TestingDirectories()

        let embedder = try NLEmbedder(language: .english)
        let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder)

        let keepUUID = UUID()
        let removeUUID = UUID()
        let keepContent = "Document to Keep"
        let removeContent = "Document to Remove"
        let keep = try await database.createDocument(uuid: keepUUID, title: "Keep", description: keepContent, embeddableContent: [.text(content: keepContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<keepContent.count)))])
        let remove = try await database.createDocument(uuid: removeUUID, title: "Remove", description: removeContent, embeddableContent: [.text(content: removeContent, location: DocumentLocation(sequenceIndex: 0, documentLength: 1, anchor: .text(characterRange: 0..<removeContent.count)))])

        try await database.deleteDocument(uuid: removeUUID)

        let expectedKeep = 1

        let globalIndexPath = FaissIndex.IndexLocation.global.filePath(in: directories.textIndexURL)
        let globalIndex = try IDMap.from(globalIndexPath.path())
        let ids = globalIndex.idMap()
        let keepID = try #require(keep.id)
        let removeID = try #require(remove.id)

        #expect(ids.filter { $0 == Int(removeID) }.isEmpty, "The deleted document's entries should be gone from the global index.")
        #expect(ids.filter { $0 == Int(keepID) }.count == expectedKeep, "The remaining document's entries should be untouched.")
        #expect(ids.count == expectedKeep, "Only the remaining document's entries should be left in the global index.")
    }
}
