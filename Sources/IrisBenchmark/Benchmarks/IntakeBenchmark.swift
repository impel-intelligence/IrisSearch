//
//  IntakeBenchmark.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation
import IrisCommon
import IrisSearch

/// Intake measurements that run against their own scratch databases: embedding throughput, parallel
/// ingest, and the cost of updating or deleting a document once the library is large.
///
/// Serial intake is not here — it is interleaved with the search checkpoints by ``BenchmarkRunner``
/// so that both are measured on the same growing database.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct IntakeBenchmark {
    let options: BenchmarkOptions

    /// Measures how fast the embedding provider turns chunk text into vectors.
    ///
    /// Every `createDocument` call embeds each of the document's chunks in sequence, so this number
    /// multiplied by chunk count is the floor for intake latency regardless of how fast SQLite and
    /// FAISS are. Separating it is what makes the intake result actionable: it says whether to optimize
    /// the database or to change the model.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureEmbeddingThroughput(
        embedder: any EmbeddingProvider,
        label: String,
        documents: [PreparedDocument],
        queries: [BenchmarkQuery]
    ) async throws -> EmbeddingReport {
        var generator = SeededGenerator(seed: options.randomSeed &+ 5)

        let allChunks = documents.prefix(400).flatMap(\.chunks).compactMap(\.textContent)
        guard !allChunks.isEmpty else {
            return EmbeddingReport(
                provider: label,
                dimension: embedder.dimension,
                chunkStats: .empty,
                chunksPerSecond: 0,
                queryStats: .empty,
                meanChunkCharacters: 0
            )
        }

        let sampleSize = min(300, allChunks.count)
        let sample = (0..<sampleSize).map { _ in allChunks.randomElement(using: &generator)! }

        // Warm the provider: the first call to a Core ML or NaturalLanguage model pays lazy setup.
        for chunk in sample.prefix(10) {
            _ = try? await embedder.embed(content: chunk)
        }

        var chunkSamples: [Double] = []
        for chunk in sample {
            let (_, duration) = try await timed {
                _ = try? await embedder.embed(content: chunk)
            }
            chunkSamples.append(duration.milliseconds)
        }

        var querySamples: [Double] = []
        for query in queries {
            for _ in 0..<5 {
                let (_, duration) = try await timed {
                    _ = try? await embedder.embedQuery(content: query.text)
                }
                querySamples.append(duration.milliseconds)
            }
        }

        let chunkStats = DurationStats(samplesInMilliseconds: chunkSamples)
        let meanCharacters = sample.reduce(0) { $0 + $1.count } / sample.count

        return EmbeddingReport(
            provider: label,
            dimension: embedder.dimension,
            chunkStats: chunkStats,
            chunksPerSecond: chunkStats.meanMilliseconds > 0 ? 1_000 / chunkStats.meanMilliseconds : 0,
            queryStats: DurationStats(samplesInMilliseconds: querySamples),
            meanChunkCharacters: meanCharacters
        )
    }

    /// Ingests the same document set at several concurrency levels, each into a fresh database.
    ///
    /// `IrisDB` is an actor whose writes funnel through a `KeyedExecutor` and a single GRDB writer, so
    /// submitting documents in parallel cannot deliver linear speedup. What this quantifies is how much
    /// of the cost is genuinely parallelizable — mainly embedding, which happens before the actor's
    /// write — and the point past which more concurrency stops helping.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureConcurrentIntake(
        documents: [PreparedDocument],
        embedder: any EmbeddingProvider,
        workingDirectory: URL
    ) async throws -> [ConcurrencyReport] {
        guard !options.intakeConcurrencySweep.isEmpty else { return [] }

        let subset = Array(documents.prefix(options.intakeConcurrencyDocuments))
        guard !subset.isEmpty else { return [] }

        let chunkTotal = subset.reduce(0) { $0 + $1.chunkCount }
        var reports: [ConcurrencyReport] = []
        var serialThroughput: Double?

        for concurrency in options.intakeConcurrencySweep {
            let location = workingDirectory.appending(path: "concurrency-\(concurrency)")
            try? FileManager.default.removeItem(at: location)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)

            let database = try IrisDB(databaseLocation: location, databaseName: "main", textEmbedder: embedder)

            let clock = ContinuousClock()
            let start = clock.now

            // Titles are unique per document, and the write executor is keyed by UUID, so distinct
            // documents are safe to submit at the same time.
            var cursor = 0
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(concurrency, subset.count) {
                    let document = subset[cursor]
                    cursor += 1
                    group.addTask {
                        try await database.createDocument(
                            uuid: document.uuid,
                            title: document.title,
                            description: document.description,
                            embeddableContent: document.chunks
                        )
                    }
                }

                while try await group.next() != nil {
                    guard cursor < subset.count else { continue }
                    let document = subset[cursor]
                    cursor += 1
                    group.addTask {
                        try await database.createDocument(
                            uuid: document.uuid,
                            title: document.title,
                            description: document.description,
                            embeddableContent: document.chunks
                        )
                    }
                }
            }

            let elapsed = (clock.now - start).seconds
            let documentsPerSecond = elapsed > 0 ? Double(subset.count) / elapsed : 0
            if concurrency == options.intakeConcurrencySweep.min() { serialThroughput = documentsPerSecond }

            reports.append(
                ConcurrencyReport(
                    concurrency: concurrency,
                    documents: subset.count,
                    chunks: chunkTotal,
                    wallClockSeconds: elapsed,
                    documentsPerSecond: documentsPerSecond,
                    chunksPerSecond: elapsed > 0 ? Double(chunkTotal) / elapsed : 0,
                    speedupVersusSerial: (serialThroughput ?? 0) > 0 ? documentsPerSecond / serialThroughput! : 1
                )
            )

            Console.info("concurrency \(concurrency): \(fixed(elapsed, 1))s for \(subset.count) docs — \(fixed(documentsPerSecond, 2)) docs/s, \(fixed(Double(chunkTotal) / max(elapsed, 0.0001), 1)) chunks/s")

            try? FileManager.default.removeItem(at: location)
        }

        return reports
    }

    /// Times `updateDocument` and `deleteDocument` on a database that is already at full size.
    ///
    /// A knowledge base that watches a folder re-indexes edited files continuously, so these costs are
    /// part of steady-state operation. Both paths rewrite the global FAISS index, so they are expected
    /// to track corpus size the same way inserts do.
    ///
    /// - Parameters:
    ///   - database: The populated database. It is mutated: sampled documents are updated and then deleted.
    ///   - candidates: Documents known to be present in `database`.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func measureMutations(
        database: IrisDB,
        candidates: [PreparedDocument],
        documentsInDatabase: Int
    ) async throws -> MutationReport? {
        guard options.mutationDocuments > 0, !candidates.isEmpty else { return nil }

        var generator = SeededGenerator(seed: options.randomSeed &+ 101)
        var sample = candidates
        sample.shuffle(using: &generator)
        sample = Array(sample.prefix(options.mutationDocuments))

        var updateSamples: [Double] = []
        for document in sample {
            do {
                let (_, duration) = try await timed {
                    try await database.updateDocument(
                        uuid: document.uuid,
                        title: document.title,
                        description: document.description + " (revised)",
                        embeddableContent: document.chunks
                    )
                }
                updateSamples.append(duration.milliseconds)
            } catch {
                Console.warn("Update of '\(document.title)' failed: \(error)")
            }
        }

        var deleteSamples: [Double] = []
        for document in sample {
            do {
                let (_, duration) = try await timed {
                    try await database.deleteDocument(uuid: document.uuid)
                }
                deleteSamples.append(duration.milliseconds)
            } catch {
                Console.warn("Delete of '\(document.title)' failed: \(error)")
            }
        }

        return MutationReport(
            documentsInDatabase: documentsInDatabase,
            updateStats: DurationStats(samplesInMilliseconds: updateSamples),
            deleteStats: DurationStats(samplesInMilliseconds: deleteSamples),
            sampledDocuments: sample.count
        )
    }
}
