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
        try WordPieceTokenizer(vocabURL: URL(filePath: "/Users/taylorlineman/Developer/impel/Minna/Packages/IrisSearch/Sources/Embedders/BGE/vocab.txt")!)
    }
}
