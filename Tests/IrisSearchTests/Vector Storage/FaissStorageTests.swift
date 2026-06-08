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
import SwiftFaissC

@Test func initialization() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "tmp-database")
    let databaseName = "main"
    
    let embedder = try NLEmbedder(language: .english)
    _ = try FaissStorage(provider: embedder, databaseLocation: tmp, databaseName: databaseName)
    
    #expect(FileManager.default.fileExists(atPath: tmp.appending(path: databaseName + ".idb").path()), "Database was not created.")
}

