//
//  Common.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import IrisCommon
import IrisSearch
import Foundation

class TestingDirectories {
    let databaseName: String = "main"
    let baseURL: URL
    let bundleURL: URL
    let sqliteURL: URL
    let textIndexURL: URL
    //    let imageIndexURL: URL
    
    init() {
        baseURL = FileManager.default.temporaryDirectory.appending(path: "tmp-database-039B1985-44EE-483C-9808-21FE954C4D93")
        bundleURL = baseURL.appendingPathComponent("\(databaseName).irisdb")
        sqliteURL = bundleURL.appending(path: "map.sqlite")
        textIndexURL = bundleURL.appending(path: "text-index")
        print(baseURL)
        //        imageIndexURL = bundleURL.appending(path: "image-index")
    }
    
    deinit {
//        try? FileManager.default.removeItem(at: baseURL)
    }
}

/// Wrap a plain string as the digester would hand it to intake: a single text content unit.
func textContent(_ string: String) -> [EmbeddableContent] {
    return [.text(content: string)]
}

extension DocumentPiece {
    /// Convenience for reading the text payload of a piece in assertions.
    var text: String? {
        if case .text(let content) = content { return content }
        return nil
    }
}

func measurePerformance(nRuns: Int = 100, _ block: @escaping () async throws -> Void) async rethrows {
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
