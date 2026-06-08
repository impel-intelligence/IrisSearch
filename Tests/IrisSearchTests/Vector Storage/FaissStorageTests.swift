//
//  FaissStorageTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/8/26.
//

import Testing
@testable import IrisSearch
import Foundation
import SwiftFaiss

@Test func initialization() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")
    let databaseName = "main"
    
    let embedder = try NLEmbedder(language: .english)
    _ = try FaissStorage(provider: embedder, databaseLocation: tmp, databaseName: databaseName)
    
    #expect(FileManager.default.fileExists(atPath: tmp.appending(path: databaseName + ".idb").path()), "Database was not created.")
}

@Test func testIndexSearching() async throws {
    let index = try FlatIndex(d: 512, metricType: .l2)

    let embedder = try NLEmbedder(language: .english)
    let chunks: [String] = [
        "Hello world",
        "Red Fish, Blue Fish"
    ]
    var embeddings: [[Float]] = []
    for chunk in chunks {
        
    }

//    try index.train(document.)
//    try index.add(<#T##xs: [[Float]]##[[Float]]#>)
    
    

}
