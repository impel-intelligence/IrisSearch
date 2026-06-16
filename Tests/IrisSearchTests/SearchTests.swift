//
//  SearchTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import Testing
@testable import IrisSearch
import IrisCommon
import Foundation
import SwiftFaiss
import SwiftFaissC
import GRDB
import XCTest

class IrisDB_SearchTests {
    @Test()
    func basicSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        nonisolated(unsafe) let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Original content"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Different"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Holy smokes"))
        try await database.createDocument(uuid: UUID(), embeddableContent: textContent("Sharks!"))
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "original"), kItems: 2)
        }
    }
    
    @Test()
    func loadedSearch() async throws {
        let directories = TestingDirectories()
        
        let embedder = try NLEmbedder(language: .english)
        nonisolated(unsafe) let database = try IrisDB(databaseLocation: directories.baseURL, databaseName: directories.databaseName, textEmbedder: embedder, textChunker: BasicTextChunker())
        
        let sonnetURL = Bundle.module.url(forResource: "Sonnets", withExtension: nil, subdirectory: "Test Documents")!
        let sonnets = try FileManager.default.contentsOfDirectory(atPath: sonnetURL.path(percentEncoded: false))
        
        for sonnet in sonnets {
            let url = sonnetURL.appendingPathComponent(sonnet, conformingTo: .plainText)
            let content = try String(contentsOf: url, encoding: .utf8)
            try await database.createDocument(uuid: UUID(), embeddableContent: textContent(content))
        }
        
        try await measurePerformance {
            _ = try await database.search(query: .init(text: "original"), kItems: 2)
        }
    }
    func measurePerformance(nRuns: Int = 100, _ block: @escaping @Sendable () async throws -> Void) async rethrows {
        let throwAwayRuns = nRuns / 10
        
        // Warmup the function
        for _ in 0..<throwAwayRuns {
            try await block()
        }

        var runs: [ContinuousClock.Instant.Duration] = []
        
        for _ in 0..<nRuns {
            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                try await block()
            }
            runs.append(elapsed)
        }

        // Convert each measured duration to seconds as a Double.
        let seconds = runs.map { run -> Double in
            let components = run.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }

        let count = Double(seconds.count)
        let average = seconds.reduce(0, +) / count

        // Sample standard deviation (matches XCTest, which uses n - 1).
        let variance = seconds.reduce(0) { $0 + ($1 - average) * ($1 - average) } / (count - 1)
        let standardDeviation = variance.squareRoot()

        // Relative standard deviation as a percentage of the average.
        let relativeStandardDeviation = average == 0 ? 0 : (standardDeviation / average) * 100

        print("measured [Time, seconds] average: \(average), relative standard deviation: \(relativeStandardDeviation), values: \(seconds)")
    }
}
