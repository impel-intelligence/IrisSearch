//
//  SearchBenchmark.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation
import IrisCommon
import IrisSearch

/// Measures query latency against a populated `IrisDB`.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct SearchBenchmark {
    let options: BenchmarkOptions

    /// The outcome of running the whole query suite once.
    struct Outcome: Sendable {
        let overall: DurationStats
        let byCategory: [String: DurationStats]
        let queryEmbedding: DurationStats
        let meanResultCount: Double
    }

    /// Runs every query `searchIterations` times after `searchWarmupIterations` untimed passes.
    ///
    /// Warmup matters because the first query against a freshly opened index pays FAISS deserialization
    /// and SQLite page cache misses; folding that into the steady-state number would misrepresent both.
    /// It is measured separately by ``measureColdSearch(queries:nItems:makeDatabase:)``.
    ///
    /// - Parameters:
    ///   - database: The populated database to query.
    ///   - queries: The query suite.
    ///   - nItems: How many results each query asks for.
    /// - Returns: Pooled and per-category latency, plus the isolated cost of embedding the query text.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureWarmSearch(
        database: IrisDB,
        embedder: any EmbeddingProvider,
        queries: [BenchmarkQuery],
        nItems: Int
    ) async throws -> Outcome {
        var pooled: [Double] = []
        var byCategory: [QueryCategory: [Double]] = [:]
        var embeddingSamples: [Double] = []
        var resultCounts: [Int] = []

        for query in queries {
            let irisQuery = IrisQuery(text: query.text)

            for _ in 0..<max(0, options.searchWarmupIterations) {
                _ = try? await database.search(query: irisQuery, nItems: nItems)
            }

            for _ in 0..<max(1, options.searchIterations) {
                do {
                    let (results, duration) = try await timed {
                        try await database.search(query: irisQuery, nItems: nItems)
                    }
                    pooled.append(duration.milliseconds)
                    byCategory[query.category, default: []].append(duration.milliseconds)
                    resultCounts.append(results.count)
                } catch {
                    Console.warn("Query '\(query.text.prefix(40))' failed: \(error)")
                    break
                }
            }

            // Time the embedding of the same query text on its own, so the report can attribute how
            // much of end-to-end search latency belongs to the model rather than to retrieval.
            for _ in 0..<max(1, options.searchIterations) {
                let (_, duration) = try await timed {
                    _ = try? await embedder.embedQuery(content: query.text.precomposedStringWithCompatibilityMapping)
                }
                embeddingSamples.append(duration.milliseconds)
            }
        }

        return Outcome(
            overall: DurationStats(samplesInMilliseconds: pooled),
            byCategory: byCategory.reduce(into: [:]) { result, entry in
                result[entry.key.rawValue] = DurationStats(samplesInMilliseconds: entry.value)
            },
            queryEmbedding: DurationStats(samplesInMilliseconds: embeddingSamples),
            meanResultCount: resultCounts.isEmpty ? 0 : Double(resultCounts.reduce(0, +)) / Double(resultCounts.count)
        )
    }

    /// Measures the first query against a freshly opened database.
    ///
    /// This is what a user pays when the app launches: `IrisDB.init` runs the migrator and opens a
    /// connection pool, and the first search deserializes the entire global FAISS index from disk. The
    /// operating system's file cache is still warm here, so this is a floor, not a worst case — a real
    /// cold boot with the file evicted from cache would be slower still.
    ///
    /// - Parameters:
    ///   - queries: Queries to issue, one per freshly created database instance.
    ///   - makeDatabase: Creates a new `IrisDB` over the same on-disk database.
    /// - Returns: Latency of the first search on each fresh instance.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureColdSearch(
        queries: [BenchmarkQuery],
        nItems: Int,
        makeDatabase: () throws -> IrisDB
    ) async throws -> DurationStats {
        var samples: [Double] = []

        for query in queries {
            var cold: IrisDB? = try makeDatabase()
            guard let cold else { continue }

            let (_, duration) = try await timed {
                _ = try? await cold.search(query: IrisQuery(text: query.text), nItems: nItems)
            }
            samples.append(duration.milliseconds)

            // Drop the instance so the next iteration cannot reuse its cached FAISS index.
            withExtendedLifetime(cold) { }
        }

        return DurationStats(samplesInMilliseconds: samples)
    }

    /// Measures `search(within:)`, which searches a single document's own FAISS index.
    ///
    /// This path scales with the size of one document rather than the whole corpus, so it is expected
    /// to stay flat as the library grows. Confirming that is part of substantiating the design.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureWithinDocumentSearch(
        database: IrisDB,
        documentIDs: [UUID],
        queries: [BenchmarkQuery],
        nItems: Int
    ) async throws -> DurationStats {
        guard !documentIDs.isEmpty else { return .empty }

        var samples: [Double] = []
        var generator = SeededGenerator(seed: options.randomSeed &+ 31)

        for query in queries {
            guard let uuid = documentIDs.randomElement(using: &generator) else { continue }
            let irisQuery = IrisQuery(text: query.text)

            for _ in 0..<max(0, options.searchWarmupIterations) {
                _ = try? await database.search(within: uuid, query: irisQuery, nItems: nItems)
            }

            for _ in 0..<max(1, options.searchIterations) {
                let (_, duration) = try await timed {
                    _ = try? await database.search(within: uuid, query: irisQuery, nItems: nItems)
                }
                samples.append(duration.milliseconds)
            }
        }

        return DurationStats(samplesInMilliseconds: samples)
    }

    /// Sweeps `nItems` to show how requesting more results changes latency.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureTopKSweep(
        database: IrisDB,
        embedder: any EmbeddingProvider,
        queries: [BenchmarkQuery],
        documentsInDatabase: Int
    ) async throws -> [TopKReport] {
        var reports: [TopKReport] = []

        for nItems in options.topKSweep {
            let outcome = try await measureWarmSearch(
                database: database,
                embedder: embedder,
                queries: queries,
                nItems: nItems
            )
            reports.append(
                TopKReport(
                    documentsInDatabase: documentsInDatabase,
                    nItems: nItems,
                    stats: outcome.overall,
                    meanResultCount: outcome.meanResultCount
                )
            )
            Console.info("  nItems=\(nItems): p50 \(fixed(outcome.overall.p50Milliseconds)) ms, p99 \(fixed(outcome.overall.p99Milliseconds)) ms, mean results \(fixed(outcome.meanResultCount, 1))")
        }

        return reports
    }
}
