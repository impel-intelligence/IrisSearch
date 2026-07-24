//
//  CoreMLRunnerTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import Foundation
import Testing
@testable import Embedders
import IrisCommon

@Suite("CoreML Runner Tests")
struct CoreMLRunnerTests {
    @Test func testModelLoading() async throws {
        let modelURL = Bundle.module.url(forResource: "bge", withExtension: nil, subdirectory: "ml")!
        let embedder = try CoreMLEmbedder(modelDirectory: modelURL)
        let embedding = try embedder.embed(content: "Hello World!")
        print(embedding)
    }
}
