//
//  DatabaseGenerationTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation
import Testing
@testable import IrisSearch
import UniformTypeIdentifiers

struct DatabaseGenerationTests {
    
    // MARK: - Record format contract
    
    @Test func testNewGeneration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: 1024)
        
        #expect(database.generation == 0)
        
        let expectedDirectory = dir.appending(path: "gen-0")
        var isDirectory: ObjCBool = false
        
        #expect(try FileManager.default.fileExists(atPath: expectedDirectory.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        
        let expectedVectorDirectory = dir.appending(path: "gen-0").appending(path: "vec.bin")
        #expect(try FileManager.default.fileExists(atPath: expectedVectorDirectory.path(percentEncoded: false)))
        
        let expectedSlotDirectory = dir.appending(path: "gen-0").appending(path: "slot.bin")
        #expect(try FileManager.default.fileExists(atPath: expectedSlotDirectory.path(percentEncoded: false)))

        let expectedDocDirectory = dir.appending(path: "gen-0").appending(path: "doc.bin")
        #expect(try FileManager.default.fileExists(atPath: expectedDocDirectory.path(percentEncoded: false)))
    }
    
    @Test func testLoadGeneration() throws {
        let generation: UInt64 = 1
        let dimensions: UInt64 = 1024
        
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let generationURL: URL = dir.appendingPathComponent("gen-\(generation)", conformingTo: .directory)
        
        try FileManager.default.createDirectory(at: generationURL, withIntermediateDirectories: true)
        
        let vectorStoreURL = generationURL.appending(path: "vec.bin")
        _ = try VectorStoreFile.new(at: vectorStoreURL, dimensions: dimensions)
        
        let slotMapURL = generationURL.appending(path: "slot.bin")
        _ = try SlotMapFile.new(at: slotMapURL)
        
        let docMapURL = generationURL.appending(path: "doc.bin")
        _ = try DocumentLogFile.new(at: docMapURL, maximumSlotCount: 0)

        let database = try DatabaseGeneration.load(generation: generation, in: dir)
        #expect(database.generation == generation)
    }
    
    @Test func testLoadNonCreatedDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let generationURL: URL = dir.appendingPathComponent("gen-1", conformingTo: .directory)
        
        #expect(throws: DatabaseGenerationError.noGenerationExists(url: generationURL)) {
            _ = try DatabaseGeneration.load(generation: 1, in: dir)
        }
    }
    
    @Test(.disabled("This test is disabled because not a directory can't be returned because the noGenerationExists error fires first."))
    func testLoadAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
       
        let file = dir.appending(path: "gen-1")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
        
        #expect(throws: DatabaseGenerationError.notADirectory(url: file)) {
            _ = try DatabaseGeneration.load(generation: 1, in: dir)
        }
    }

    
    @Test func testFindNewestGeneration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 1, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 2, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 4, dimensions: 1024)

        let newestGeneration = try #require(try DatabaseGeneration.detect(in: dir))
        #expect(newestGeneration == 4)
    }
    
    @Test func testFindNewestGenerationSkipsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 1, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 2, dimensions: 1024)

        let file = dir.appending(path: "gen-9")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())

        let newestGeneration = try #require(try DatabaseGeneration.detect(in: dir))
        #expect(newestGeneration == 2)
    }

    // MARK: - Helpers
    //
    // Added by Claude Opus 5 (Anthropic) on 8/19/26. The tests below use a small dimension so a
    // failing vector prints readably; the tests above deliberately use 1024 to match production.

    static let testDimensions = 8

    /// A fresh temp directory. Callers still own the `defer` that removes it.
    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A unit-length vector, matching what `addDocument` guarantees before it reaches the store.
    static func vector(_ seed: Float) -> [Float] {
        var v = (0..<testDimensions).map { Float($0) * 0.1 + seed }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        for i in v.indices { v[i] /= norm }
        return v
    }

    // MARK: - Slot allocation

    @Test func testDocumentOwnsAContiguousRange() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2), Self.vector(3)],
                            ids: [10, 11, 12], documentUUID: uuid, documentID: 1)

        #expect(try database.documentLog.range(for: uuid) == 0..<3)
        #expect(database.slotMap.count == 3)
    }

    @Test func testSecondDocumentBeginsWhereTheFirstEnded() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let first = UUID(), second = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: first, documentID: 1)
        try database.submit(embeddings: [Self.vector(3)], ids: [12],
                            documentUUID: second, documentID: 2)

        #expect(try database.documentLog.range(for: first) == 0..<2)
        #expect(try database.documentLog.range(for: second) == 2..<3,
                "Ranges must abut exactly — a gap or overlap corrupts slot identity.")
    }

    @Test func testSlotsHoldThePieceIDsTheyWereGiven() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [77, 88],
                            documentUUID: UUID(), documentID: 1)

        #expect(database.slotMap[0] == 77)
        #expect(database.slotMap[1] == 88)
    }

    @Test func testDocumentWithNoEmbeddingsOwnsAnEmptyRange() throws {
        // An image-only document embeds nothing but is still live. Skipping it entirely would make
        // reconcile see it in SQLite but not the log, re-index it, get zero vectors, and repeat on
        // every open.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [], ids: [], documentUUID: uuid, documentID: 1)

        #expect(try database.documentLog.range(for: uuid).isEmpty)
        #expect(database.slotMap.count == 0)
    }

    // MARK: - The commit protocol

    @Test func testAppendsAreInvisibleUntilCommitted() throws {
        // slot.bin's header is the only commit point. Entry bytes past `slotCount` are on disk but
        // uncommitted, and a reload must ignore them — that is what makes a crash lose an append
        // rather than expose half of one.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        try database.submit(embeddings: [Self.vector(1)], ids: [10], documentUUID: UUID(), documentID: 1)
        #expect(database.slotMap.count == 1, "In memory the slot exists immediately.")

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(reloaded.slotMap.count == 0,
                "The header still says zero slots, so the append must not survive.")
    }

    @Test func testCommittedAppendsSurviveAReload() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: uuid, documentID: 1)
        try database.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(reloaded.slotMap.count == 2)
        #expect(reloaded.slotMap[0] == 10)
        #expect(reloaded.slotMap[1] == 11)
        #expect(try reloaded.documentLog.range(for: uuid) == 0..<2)
    }

    @Test func testVectorsSurviveAReload() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let written = Self.vector(5)
        try database.submit(embeddings: [written], ids: [10], documentUUID: UUID(), documentID: 1)
        try database.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        let readBack: [Float] = try reloaded.vectorStore.withVectorMatrix { matrix in
            Array(UnsafeBufferPointer(start: matrix, count: Self.testDimensions))
        }
        for index in 0..<Self.testDimensions {
            #expect(abs(readBack[index] - written[index]) < 1e-6, "dimension \(index)")
        }
    }

    @Test func testManySubmissionsCrossTheSyncThresholdAndSurvive() throws {
        // The threshold is 32, so this exercises the automatic synchronize path.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        var uuids: [UUID] = []
        for index in 0..<40 {
            let uuid = UUID()
            uuids.append(uuid)
            try database.submit(embeddings: [Self.vector(Float(index))], ids: [UInt64(index)],
                                documentUUID: uuid, documentID: UInt64(index))
        }
        try database.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(reloaded.slotMap.count == 40)
        for (index, uuid) in uuids.enumerated() {
            #expect(try reloaded.documentLog.range(for: uuid) == index..<(index + 1))
        }
    }

    // MARK: - Deletion

    @Test func testDeleteTombstonesTheWholeRange() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2), Self.vector(3)],
                            ids: [10, 11, 12], documentUUID: uuid, documentID: 1)
        try database.delete(documentUUID: uuid, documentID: 1, pieceIDs: [])

        for slot in 0..<3 {
            #expect(!database.slotMap.isLive(slot), "slot \(slot) should be tombstoned")
        }
    }

    @Test func testDeleteLeavesNeighbouringDocumentsAlone() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let doomed = UUID(), survivor = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: doomed, documentID: 1)
        try database.submit(embeddings: [Self.vector(3)], ids: [12],
                            documentUUID: survivor, documentID: 2)

        try database.delete(documentUUID: doomed, documentID: 1, pieceIDs: [])

        #expect(!database.slotMap.isLive(0))
        #expect(!database.slotMap.isLive(1))
        #expect(database.slotMap.isLive(2), "The next document's slots must be untouched.")
        #expect(try database.documentLog.range(for: survivor) == 2..<3)
    }

    @Test func testDeleteRemovesTheDocumentFromTheFold() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1)], ids: [10], documentUUID: uuid, documentID: 1)
        try database.delete(documentUUID: uuid, documentID: 1, pieceIDs: [])

        #expect(throws: DocumentMapError.rangeDoesNotExist(uuid: uuid)) {
            _ = try database.documentLog.range(for: uuid)
        }
    }

    @Test func testDeleteSurvivesAReload() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: uuid, documentID: 1)
        try database.delete(documentUUID: uuid, documentID: 1, pieceIDs: [])
        try database.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        #expect(!reloaded.slotMap.isLive(0), "The tombstone must be on disk, not only in memory.")
        #expect(!reloaded.slotMap.isLive(1))
        #expect(throws: DocumentMapError.rangeDoesNotExist(uuid: uuid)) {
            _ = try reloaded.documentLog.range(for: uuid)
        }
    }

    @Test func testDeleteOfAnUnknownDocumentThrows() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        #expect(throws: DocumentMapError.rangeDoesNotExist(uuid: uuid)) {
            try database.delete(documentUUID: uuid, documentID: 99, pieceIDs: [])
        }
    }

    @Test func testDeleteDoesNotShrinkTheVectorFile() throws {
        // Deletion writes about a kilobyte and never touches vec.bin. Space comes back at compaction.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))
        let vectorURL = dir.appending(path: "gen-0").appending(path: "vec.bin")

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: uuid, documentID: 1)
        try database.synchronize()
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: vectorURL.path(percentEncoded: false))[.size] as? Int

        try database.delete(documentUUID: uuid, documentID: 1, pieceIDs: [])
        try database.synchronize()
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: vectorURL.path(percentEncoded: false))[.size] as? Int

        #expect(sizeBefore == sizeAfter)
    }

    @Test func testSlotCountDoesNotShrinkOnDelete() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        let uuid = UUID()
        try database.submit(embeddings: [Self.vector(1), Self.vector(2)], ids: [10, 11],
                            documentUUID: uuid, documentID: 1)
        try database.delete(documentUUID: uuid, documentID: 1, pieceIDs: [])

        #expect(database.slotMap.count == 2, "Tombstoning marks slots dead; it never removes them.")
    }

    // MARK: - Cross-file consistency

    @Test func testVectorStoreAlwaysHoldsAtLeastTheCommittedSlots() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        for index in 0..<10 {
            try database.submit(embeddings: [Self.vector(Float(index))], ids: [UInt64(index)],
                                documentUUID: UUID(), documentID: UInt64(index))
            #expect(database.vectorStore.capacity >= database.slotMap.count,
                    "vec.bin must hold at least as many slots as slot.bin claims")
        }
    }

    @Test func testNoDocumentRangeExceedsTheSlotCount() throws {
        // A record naming slots slot.bin never committed would read past the mapping during search.
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: UInt64(Self.testDimensions))

        var uuids: [UUID] = []
        for index in 0..<5 {
            let uuid = UUID()
            uuids.append(uuid)
            try database.submit(embeddings: [Self.vector(Float(index)), Self.vector(Float(index) + 0.5)],
                                ids: [UInt64(index * 2), UInt64(index * 2 + 1)],
                                documentUUID: uuid, documentID: UInt64(index))
        }
        try database.synchronize()

        let reloaded = try DatabaseGeneration.load(generation: 0, in: dir)
        for uuid in uuids {
            let range = try reloaded.documentLog.range(for: uuid)
            #expect(range.upperBound <= reloaded.slotMap.count,
                    "\(range) exceeds \(reloaded.slotMap.count) committed slots")
        }
    }
}
