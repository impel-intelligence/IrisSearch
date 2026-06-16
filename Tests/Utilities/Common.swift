//
//  Common.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import IrisCommon
import Foundation

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

public func measurePerformance(nRuns: Int = 100, _ block: @escaping () async throws -> Void) async rethrows {
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
