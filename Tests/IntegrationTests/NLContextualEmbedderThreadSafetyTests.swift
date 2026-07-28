//
//  NLContextualEmbedderThreadSafetyTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/20/26.
//

import Testing
import NaturalLanguage
@testable import IrisSearch
import AppleIntelligenceEmbedder

@Suite struct NLContextualEmbedderThreadSafetyTests {
    /// Documents the underlying bug: calling `NLContextualEmbedding.embeddingResult`
    /// concurrently on a shared instance is a data race that crashes with
    /// `EXC_BAD_ACCESS`. Disabled because it intentionally crashes the test process —
    /// re-enable it manually (ideally under Thread Sanitizer) to reproduce the race.
    /// The real, lock-guarded path is covered by `lockGuardedEmbedderIsConcurrencySafe`.
    @Test(.disabled("Intentionally races a non-Sendable model; crashes the test process."))
    func concurrentInferenceMatchesSerialBaseline() async throws {
        guard let model = NLContextualEmbedding(language: .english) else {
            Issue.record("Model unavailable on this machine"); return
        }
        try model.load()

        let input = "The quick brown fox jumps over the lazy dog."
        func firstVector() throws -> [Float] {
            let r = try model.embeddingResult(for: input, language: .english)
            var out: [Float] = []
            r.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vec, _ in
                out = vec.map(Float.init); return false
            }
            return out
        }

        let baseline = try firstVector()
        #expect(!baseline.isEmpty)

        // nonisolated(unsafe) only to share the model into tasks for the experiment.
        nonisolated(unsafe) let sharedModel = model
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for _ in 0..<500 {
                group.addTask {
                    let r = try sharedModel.embeddingResult(for: input, language: .english)
                    var out: [Float] = []
                    r.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vec, _ in
                        out = vec.map(Float.init); return false
                    }
                    return out
                }
            }
            for try await v in group {
                #expect(v == baseline)   // mismatch => internal state corruption
            }
        }
    }

    /// The lock-guarded `NLContextualEmbedder` must survive the same concurrent load
    /// that crashes the raw model. Run under Thread Sanitizer: no crash and no TSan
    /// report confirms the lock genuinely serializes access.
    @Test func lockGuardedEmbedderIsConcurrencySafe() async throws {
        let embedder: NLContextualEmbedder
        do {
            embedder = try NLContextualEmbedder()
        } catch {
            Issue.record("Model unavailable on this machine: \(error)"); return
        }

        let inputs = [
            "The quick brown fox jumps over the lazy dog.",
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
            "Concurrency without a lock corrupts the model's internal state.",
        ]

        let baseline = try await embedder.embed(content: inputs[0])
        #expect(!baseline.isEmpty)

        try await withThrowingTaskGroup(of: (Int, [Double]).self) { group in
            for iteration in 0..<500 {
                let content = inputs[iteration % inputs.count]
                group.addTask { (iteration % inputs.count, try await embedder.embed(content: content)) }
            }
            for try await (inputIndex, vector) in group {
                // Same input must always yield the same vector under contention.
                if inputIndex == 0 {
                    #expect(vector == baseline)
                }
                #expect(!vector.isEmpty)
            }
        }
    }
}
