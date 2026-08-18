//
//  VectorStoreTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/12/26.
//

import Foundation
import Testing
@testable import IrisSearch

struct VectorStoreTests {
    @Test("Test creating a new Vector Store File")
    func testNewFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "vec.bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try VectorStoreFile.new(at: tmp, dimensions: 1024)
        #expect(file.header.dimensions == 1024)
    }
    
    @Test("Testing adding a vector to the vector store")
    func testAddSingleVector() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "vec.bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try VectorStoreFile.new(at: tmp, dimensions: 3)
        
        try file.reserve(slot: 1)
        
        let vectors: [[Float]] = [[1.0, 2.0, 3.0]]
        
        let range = try file.write(vectors: vectors, at: 0)
        #expect(range == 0..<1)
    }

    @Test("Testing adding a vector to the vector store")
    func testAddMultipleVectors() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "vec.bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try VectorStoreFile.new(at: tmp, dimensions: 3)
        
        try file.reserve(slot: 2)
        
        let vectors: [[Float]] = [[1.0, 2.0, 3.0], [3.0, 5.0, 1.0]]
        
        let range = try file.write(vectors: vectors, at: 0)
        #expect(range == 0..<2)
    }

    
    @Test("Testing adding vector in the middle")
    func testAddVectorInMiddle() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "vec.bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try VectorStoreFile.new(at: tmp, dimensions: 3)
        
        try file.reserve(slot: 5)
        
        let vectors: [[Float]] = [[1.0, 2.0, 3.0], [3.0, 5.0, 1.0]]
        
        let range = try file.write(vectors: vectors, at: 2)
        #expect(range == 2..<4)
    }
    
    @Test("Test requesting vector storage")
    func testRetrieveVectors() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "vec.bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try VectorStoreFile.new(at: tmp, dimensions: 3)
        try file.reserve(slot: 2)
        
        let vectors: [[Float]] = [[1.0, 2.0, 3.0], [3.0, 5.0, 1.0]]

        _ = try file.write(vectors: vectors, at: 0)
        
        let vector: [Float] = try file.withVectorMatrix { base in
            Array(UnsafeBufferPointer(start: base, count: file.dimensions))
        }
        
        #expect(vector == vectors.first)
    }

}
