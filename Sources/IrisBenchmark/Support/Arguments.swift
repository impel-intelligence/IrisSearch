//
//  Arguments.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import ArgumentParser
import Foundation

/// Which embedding provider the benchmark drives the database with.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum EmbedderKind: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
    /// `NLEmbedder`, Apple's sentence embedding.
    case naturalLanguage = "nl"
    /// `NLContextualEmbedder`, Apple's transformer-based contextual embedding.
    case contextual
    /// `CoreMLEmbedder` loaded from `--coreml-model`. This is what the app ships.
    case coreml
    /// A deterministic feature-hashing embedder. Costs almost nothing, so it isolates the cost of the
    /// database and index from the cost of the embedding model.
    case hash
}

/// Everything a benchmark run is parameterized by.
///
/// This is the configuration the benchmark phases read. Parsing lives in ``IrisBenchmarkCommand``,
/// which builds one of these; keeping them separate means the measurement code never has to know
/// where its settings came from.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct BenchmarkOptions: Sendable {
    var corpusRoots: [URL] = []
    var cacheDirectory: URL
    var outputDirectory: URL
    var workingDirectory: URL

    var embedderKind: EmbedderKind = .naturalLanguage
    var coreMLModelDirectory: URL?
    var hashDimension: Int = 512

    /// Document counts at which the search suite is run.
    ///
    /// The default ceiling is deliberately modest. `FaissIndex` rewrites the entire global index file
    /// on every insert, so the bytes a run writes grow with the square of the document count — pushing
    /// the top checkpoint to 10,000 costs terabytes of disk writes and hours of wall clock.
    var checkpoints: [Int] = [100, 250, 500, 1_000, 2_000]
    /// Hard ceiling on documents ingested. Defaults to the largest checkpoint.
    var maxDocuments: Int?
    /// Chunk size handed to the digesters, matching `IrisDB.contextSize`.
    var contextSize: Int = 512

    /// Number of generated queries per query category.
    var queriesPerCategory: Int = 6
    /// Timed repetitions of each query at each checkpoint.
    var searchIterations: Int = 12
    /// Untimed repetitions run before the timed ones.
    var searchWarmupIterations: Int = 3
    /// `nItems` values swept at the final checkpoint.
    var topKSweep: [Int] = [5, 10, 25, 50]

    /// Keep PDF page images. They are never embedded and only inflate SQLite, so they are off by default.
    var includeImages: Bool = false
    /// Allow padding the corpus with documents recombined from real chunks once real files run out.
    var allowSynthetic: Bool = true
    /// Concurrency levels measured by the parallel-intake phase. Empty disables the phase.
    var intakeConcurrencySweep: [Int] = [1, 2, 4, 8]
    /// Documents used by the parallel-intake phase at each concurrency level.
    var intakeConcurrencyDocuments: Int = 150
    /// Documents sampled for the update and delete phase.
    var mutationDocuments: Int = 50

    /// Seed for every sampling decision, so a run with the same seed sees the same corpus and queries.
    var randomSeed: UInt64 = 0xC0FFEE
    /// Reuse the on-disk chunk cache when it is valid, instead of re-digesting.
    var useCache: Bool = true
    /// Print each ingested document as it lands.
    var verbose: Bool = false

    /// The largest document count the run needs to reach.
    var targetDocumentCount: Int {
        maxDocuments ?? (checkpoints.max() ?? 1_000)
    }

    init() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        cacheDirectory = cwd.appending(path: ".benchmark-cache")
        outputDirectory = cwd.appending(path: "BenchmarkResults")
        workingDirectory = FileManager.default.temporaryDirectory.appending(path: "iris-benchmark-\(UUID().uuidString)")
    }
}

/// A small reproducible random number generator so a seeded run is repeatable.
///
/// Uses SplitMix64, which is fast and has good distribution for the sampling this tool does.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
