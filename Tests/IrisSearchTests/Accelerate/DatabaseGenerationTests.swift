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

}
