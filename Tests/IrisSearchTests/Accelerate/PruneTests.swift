//
//  PruneTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/31/26.
//

import Foundation
import Testing
import GRDB
@testable import IrisSearch
@testable import IrisCommon

struct PruneTests {
    /// `AccelerateIndex` only reads `dimension` from its provider — embedding happens upstream in
    /// `IrisDB`, so repair never calls `embed`.
    final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let dimension: Int
        init(dimension: Int) { self.dimension = dimension }
        func embed(content: String) async throws -> [Double] {
            fatalError("repair must never embed")
        }
    }

    @Test
    func testPruneRemovesAllOtherGenerations() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create 4 generations
        _ = try DatabaseGeneration.new(at: dir, generation: 0, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 1, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 2, dimensions: 1024)
        _ = try DatabaseGeneration.new(at: dir, generation: 3, dimensions: 1024)
        
        // Set the current generation to 4
        try DatabaseGeneration.writeCurrentDatabasePointer(for: 3, in: dir)
        
        // 4 generations + 1 pointer
        let beforeFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: []).map(\.lastPathComponent)
        #expect(beforeFiles.count == 5)
        print(beforeFiles)
        #expect(["gen-0", "gen-1", "gen-2", "gen-3"].allSatisfy({beforeFiles.contains($0)}))
        
        // Create an index
        let index = try AccelerateIndex(indexLocation: dir, embeddingProvider: StubEmbedder(dimension: 1024))
        
        try index.pruneGenerations(except: 3)

        // 1 generation + 1 pointer
        let afterPruneFiles = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: []).map(\.lastPathComponent)
        #expect(afterPruneFiles.count == 2)
        #expect(afterPruneFiles.contains("gen-3"))
    }
}
