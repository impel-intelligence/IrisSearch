//
//  Common.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import IrisCommon
import Foundation
import Testing

public class TestingDirectories {
    let uuid: UUID = UUID()
    
    public let databaseName: String = "main"
    public let baseURL: URL
    public let bundleURL: URL
    public let sqliteURL: URL
    public let textIndexURL: URL
    //    let imageIndexURL: URL
    
    public init() {
        baseURL = FileManager.default.temporaryDirectory.appending(path: "tmp-database-\(uuid)")
        bundleURL = baseURL.appendingPathComponent("\(databaseName).irisdb")
        sqliteURL = bundleURL.appending(path: "map.sqlite")
        textIndexURL = bundleURL.appending(path: "text-index")
        //        imageIndexURL = bundleURL.appending(path: "image-index")
    }
    
    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

public struct PerformanceBundle {
    public let average: Double
    public let variance: Double
    public let standardDeviation: Double
    public let relativeStandardDeviation: Double
    public let values: [Double]
}

// Edited by Claude Sonnet 5 (Anthropic) on 2026-07-13.
/// Builds an array of `.text` embeddable content pieces from `texts`, standing in for what a `Digester`'s
/// chunker would produce. `IrisDB` no longer chunks content itself, so tests that need multiple document
/// pieces must supply them pre-chunked, exactly as a real digester now would.
public func chunkedEmbeddableContent(_ texts: [String]) -> [EmbeddableContent] {
    texts.enumerated().map { offset, text in
        EmbeddableContent.text(
            content: text,
            location: DocumentLocation(sequenceIndex: offset, documentLength: texts.count, anchor: .text(characterRange: 0..<text.count))
        )
    }
}


@discardableResult
public func measurePerformance<Element>(nRuns: Int = 10, array: [Element] , _ block: @escaping (Element) async throws -> Void) async rethrows -> PerformanceBundle {
    let throwAwayRuns = nRuns / 10
    
    // Warmup the function
    for _ in 0..<throwAwayRuns {
        for element in array {
            try await block(element)
        }
    }
    
    var runs: [ContinuousClock.Instant.Duration] = []
    
    for _ in 0..<nRuns {
        for element in array {
            let clock = ContinuousClock()
            
            let elapsed = try await clock.measure {
                try await block(element)
            }
            
            runs.append(elapsed)
        }
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
    
    return PerformanceBundle(average: average, variance: variance, standardDeviation: standardDeviation, relativeStandardDeviation: relativeStandardDeviation, values: seconds)
}

@discardableResult
public func measurePerformance(nRuns: Int = 100, _ block: @escaping () async throws -> Void) async rethrows -> PerformanceBundle {
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
    
    return PerformanceBundle(average: average, variance: variance, standardDeviation: standardDeviation, relativeStandardDeviation: relativeStandardDeviation, values: seconds)
}

public extension Testing.Tag {
    @Tag static var lfs: Self
    @Tag static var network: Self
    @Tag static var arxiv: Self
}

