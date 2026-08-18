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
        _ = try DocumentMapFile.new(at: docMapURL, maximumSlotCount: 0)

        let database = try DatabaseGeneration.load(generation: generation, in: dir)
        #expect(database.generation == generation)
    }
}
