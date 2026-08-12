//
//  Results.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation

/// The full machine readable result of a benchmark run.
///
/// Written to `results.json` so runs can be diffed against each other to catch regressions.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct BenchmarkReport: Codable, Sendable {
    let host: HostInformation
    let configuration: ConfigurationSummary
    let corpus: CorpusSummary
    let digestion: DigestionReport
    let embedding: EmbeddingReport
    let checkpoints: [CheckpointReport]
    let intakeScaling: ScalingFit?
    let searchScaling: ScalingFit?
    let topK: [TopKReport]
    let concurrency: [ConcurrencyReport]
    let mutation: MutationReport?
    let totalRunSeconds: Double
}

/// The parameters the run was executed with.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct ConfigurationSummary: Codable, Sendable {
    let corpusRoots: [String]
    let embedder: String
    let embedderKind: EmbedderKind
    let embeddingDimension: Int
    let contextSize: Int
    let checkpoints: [Int]
    let targetDocumentCount: Int
    let includeImages: Bool
    let allowSynthetic: Bool
    let searchIterations: Int
    let searchWarmupIterations: Int
    let randomSeed: UInt64
    let queries: [BenchmarkQuery]
}

/// What the corpus actually contained.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct CorpusSummary: Codable, Sendable {
    let realDocuments: Int
    let syntheticDocuments: Int
    let totalDocuments: Int
    let totalChunks: Int
    let totalTextCharacters: Int
    let meanChunksPerDocument: Double
    let medianChunksPerDocument: Int
    let maxChunksPerDocument: Int
    let meanCharactersPerChunk: Double
    let documentsByKind: [String: Int]
    let chunksByKind: [String: Int]
    let skippedFileCount: Int
}

/// How fast documents are turned into chunks, broken down by file format.
///
/// This is the `Digester` module rather than the search database, but it is the first half of what a
/// user experiences as "adding a document", so a claim about intake speed is incomplete without it.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct DigestionReport: Codable, Sendable {
    struct PerKind: Codable, Sendable {
        let kind: String
        let files: Int
        let stats: DurationStats
        let megabytesPerSecond: Double
        let chunksPerSecond: Double
    }

    let measuredFiles: Int
    let cachedFiles: Int
    let overall: DurationStats
    let byKind: [PerKind]
}

/// Embedding provider throughput, measured on real chunk text.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct EmbeddingReport: Codable, Sendable {
    let provider: String
    let dimension: Int
    let chunkStats: DurationStats
    let chunksPerSecond: Double
    let queryStats: DurationStats
    let meanChunkCharacters: Int
}

/// Everything measured once the database holds a given number of documents.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct CheckpointReport: Codable, Sendable {
    let documentsInDatabase: Int
    let chunksInDatabase: Int
    let vectorsInIndex: Int

    /// Per-document `createDocument` cost for the documents ingested since the previous checkpoint.
    let intakeStats: DurationStats
    /// Per-chunk intake cost over the same window.
    let intakeMillisecondsPerChunk: Double
    let intakeChunksPerSecond: Double
    let intakeDocumentsPerSecond: Double
    /// Cumulative wall clock spent ingesting, from the first document to this checkpoint.
    let cumulativeIntakeSeconds: Double

    /// Warm search latency, all categories pooled.
    let searchOverall: DurationStats
    /// Warm search latency per query category.
    let searchByCategory: [String: DurationStats]
    /// Cost of embedding the query text alone, the share of search that belongs to the model.
    let queryEmbeddingStats: DurationStats
    /// First search against a freshly opened database, paying index load and cold page cache.
    let coldSearchStats: DurationStats
    /// `search(within:)`, the single-document path.
    let withinDocumentSearchStats: DurationStats
    /// Mean number of documents returned by a warm search.
    let meanResultCount: Double

    let sqliteBytes: UInt64
    let globalIndexBytes: UInt64
    let perDocumentIndexBytes: UInt64
    let indexFileCount: Int
    let totalDatabaseBytes: UInt64
    let memoryFootprintBytes: UInt64

    /// Cumulative bytes the global FAISS index has been rewritten with since the first insert.
    ///
    /// `FaissIndex.add(pieces:to:)` saves the whole global index after every document, so this grows
    /// with the square of the document count. It is the mechanism behind the intake curve, and it is
    /// also real write amplification against the user's disk, so it is reported rather than inferred.
    let cumulativeGlobalIndexWriteBytes: UInt64
}

/// A fitted `cost ≈ coefficient × size^exponent` relationship.
///
/// Both the fit over every checkpoint and the fit with the smallest checkpoint dropped are reported.
/// The smallest corpus size is the one most exposed to first-touch effects — page cache, allocator
/// growth, lazily initialized library state — and with only a handful of checkpoints a single
/// distorted point moves the exponent enough to change the stated conclusion. Publishing both, with
/// their `rSquared`, makes that visible instead of letting it silently pick an answer.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct ScalingFit: Codable, Sendable {
    let subject: String
    /// What the cost was fitted against, for example "vectors in index".
    let independentVariable: String
    let exponent: Double
    let coefficient: Double
    let rSquared: Double
    let pointCount: Int
    /// The same fit with the smallest checkpoint excluded, when there are enough points for one.
    let exponentExcludingSmallest: Double?
    let rSquaredExcludingSmallest: Double?
    let interpretation: String
}

/// Search latency as a function of how many results are requested.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct TopKReport: Codable, Sendable {
    let documentsInDatabase: Int
    let nItems: Int
    let stats: DurationStats
    let meanResultCount: Double
}

/// Intake throughput when documents are submitted concurrently.
///
/// `IrisDB` is an actor and serializes its own writes, so this quantifies how much real parallelism
/// the design allows and where it stops paying.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct ConcurrencyReport: Codable, Sendable {
    let concurrency: Int
    let documents: Int
    let chunks: Int
    let wallClockSeconds: Double
    let documentsPerSecond: Double
    let chunksPerSecond: Double
    let speedupVersusSerial: Double
}

/// Update and delete costs on a populated database.
///
/// A knowledge base that tracks a folder re-indexes changed files constantly, so these are part of
/// steady-state intake cost rather than a separate concern.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct MutationReport: Codable, Sendable {
    let documentsInDatabase: Int
    let updateStats: DurationStats
    let deleteStats: DurationStats
    let sampledDocuments: Int
}
