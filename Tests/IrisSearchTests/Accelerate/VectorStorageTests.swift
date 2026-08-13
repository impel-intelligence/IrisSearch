//
//  VectorStorageTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/12/26.
//

import Foundation
import Testing
@testable import IrisSearch

struct VectorStorageTests {
    @Test func testNewLoad() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "index.idx")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let storage = try VectorStorage.new(at: tmp, dimensions: 1024)
        #expect(storage.header.dimensions == 1024)
    }
}
