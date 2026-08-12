//
//  BenchmarkRunner.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation
import IrisCommon
import IrisSearch

/// Drives the whole benchmark: builds the corpus, grows a database through the configured document
/// counts, and measures search at each one.
///
/// Intake and search are deliberately measured on the *same* database as it grows, rather than on
/// separate fixtures. That is the only way to see both curves against a single, comparable x-axis.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct BenchmarkRunner {
    let options: BenchmarkOptions

    /// Runs every phase and returns the assembled report.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func run() async throws -> BenchmarkReport {
        let runClock = ContinuousClock()
        let runStart = runClock.now

        let host = HostInformation.current()
        Console.heading("Host")
        Console.info("\(host.cpuModel), \(host.logicalCores) cores, \(formatBytes(host.physicalMemoryBytes)) RAM, \(host.operatingSystem)")
        Console.info("Build configuration: \(host.swiftBuildConfiguration)")
        if host.swiftBuildConfiguration == "debug" {
            Console.warn("Running a debug build. Numbers will be several times slower than release. Use: swift run -c release IrisBenchmark")
        }

        // MARK: Corpus
        Console.heading("Corpus")
        let corpus = try await CorpusBuilder(options: options).build()
        let corpusSummary = summarize(corpus)
        logCorpus(corpusSummary)

        // MARK: Embedder
        let (embedder, embedderLabel) = try EmbedderFactory.makeEmbedder(options: options)
        Console.heading("Embedding provider")
        Console.info(embedderLabel)

        // MARK: Queries
        let queries = QuerySuiteBuilder(options: options).build(from: corpus.documents)
        Console.heading("Query suite")
        Console.info("\(queries.count) queries across \(Set(queries.map(\.category)).count) categories.")
        for category in QueryCategory.allCases {
            let examples = queries.filter { $0.category == category }.prefix(2).map { "\"\($0.text.prefix(48))\"" }
            guard !examples.isEmpty else { continue }
            Console.info("  \(category.displayName): \(examples.joined(separator: ", "))")
        }

        // MARK: Embedding throughput
        Console.heading("Embedding throughput")
        let intake = IntakeBenchmark(options: options)
        let embeddingReport = try await intake.measureEmbeddingThroughput(
            embedder: embedder,
            label: embedderLabel,
            documents: corpus.documents,
            queries: queries
        )
        Console.info("Chunk embedding: mean \(fixed(embeddingReport.chunkStats.meanMilliseconds, 3)) ms, p99 \(fixed(embeddingReport.chunkStats.p99Milliseconds, 3)) ms — \(fixed(embeddingReport.chunksPerSecond, 1)) chunks/s (mean chunk \(embeddingReport.meanChunkCharacters) chars)")
        Console.info("Query embedding: mean \(fixed(embeddingReport.queryStats.meanMilliseconds, 3)) ms")

        // MARK: Intake and search across corpus sizes
        let checkpointResults = try await runGrowthPhases(
            corpus: corpus,
            embedder: embedder,
            queries: queries,
            embeddingReport: embeddingReport
        )

        // MARK: Scaling fits
        //
        // Fitted against vectors rather than documents. Documents vary enormously in length — this
        // corpus runs from 1 chunk to 2,738 — so document count is a noisy proxy. The FAISS scan and
        // the FTS5 postings lists both grow with chunks, which is what `vectorsInIndex` counts.
        let intakeFit = makeScalingFit(
            subject: "per-document intake",
            checkpoints: checkpointResults.checkpoints,
            value: { $0.intakeStats.meanMilliseconds }
        )

        let searchFit = makeScalingFit(
            subject: "median search latency",
            checkpoints: checkpointResults.checkpoints,
            value: { $0.searchOverall.p50Milliseconds }
        )

        // MARK: Concurrency
        Console.heading("Parallel intake")
        let concurrency = try await intake.measureConcurrentIntake(
            documents: corpus.documents,
            embedder: embedder,
            workingDirectory: options.workingDirectory
        )

        let totalSeconds = (runClock.now - runStart).seconds

        return BenchmarkReport(
            host: host,
            configuration: ConfigurationSummary(
                corpusRoots: options.corpusRoots.map { $0.path(percentEncoded: false) },
                embedder: embedderLabel,
                embedderKind: options.embedderKind,
                embeddingDimension: embedder.dimension,
                contextSize: options.contextSize,
                checkpoints: options.checkpoints,
                targetDocumentCount: options.targetDocumentCount,
                includeImages: options.includeImages,
                allowSynthetic: options.allowSynthetic,
                searchIterations: options.searchIterations,
                searchWarmupIterations: options.searchWarmupIterations,
                randomSeed: options.randomSeed,
                queries: queries
            ),
            corpus: corpusSummary,
            digestion: digestionReport(from: corpus),
            embedding: embeddingReport,
            checkpoints: checkpointResults.checkpoints,
            intakeScaling: intakeFit,
            searchScaling: searchFit,
            topK: checkpointResults.topK,
            concurrency: concurrency,
            mutation: checkpointResults.mutation,
            totalRunSeconds: totalSeconds
        )
    }
}

// MARK: - Growth phases

extension BenchmarkRunner {
    /// The results produced while growing the database.
    struct GrowthResults {
        var checkpoints: [CheckpointReport] = []
        var topK: [TopKReport] = []
        var mutation: MutationReport?
        var intakeSeries: [IntakeSample] = []
    }

    /// One ingested document's timing, recorded for the per-document CSV.
    struct IntakeSample: Sendable {
        let ordinal: Int
        let documentsInDatabase: Int
        let chunksInDatabase: Int
        let chunkCount: Int
        let milliseconds: Double
        let origin: DocumentOrigin
    }

    /// Ingests documents one at a time, pausing at each checkpoint to run the search suite.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func runGrowthPhases(
        corpus: CorpusBuilder.Result,
        embedder: any EmbeddingProvider,
        queries: [BenchmarkQuery],
        embeddingReport: EmbeddingReport
    ) async throws -> GrowthResults {
        let databaseLocation = options.workingDirectory.appending(path: "primary")
        try? FileManager.default.removeItem(at: databaseLocation)
        try FileManager.default.createDirectory(at: databaseLocation, withIntermediateDirectories: true)

        let bundleURL = databaseLocation.appending(path: "main.irisdb")
        let sqliteURL = bundleURL.appending(path: "map.sqlite")
        let indexDirectory = bundleURL.appending(path: "text-index")
        let globalIndexURL = indexDirectory.appending(path: "global.index")

        func makeDatabase() throws -> IrisDB {
            try IrisDB(databaseLocation: databaseLocation, databaseName: "main", textEmbedder: embedder)
        }

        var database: IrisDB! = try makeDatabase()

        let documents = corpus.documents
        let reachableCheckpoints = options.checkpoints
            .filter { $0 <= documents.count }
            .sorted()
        let finalTarget = reachableCheckpoints.last ?? documents.count

        if reachableCheckpoints.isEmpty {
            Console.warn("No configured checkpoint is reachable with \(documents.count) documents.")
        }

        var results = GrowthResults()
        let searchBenchmark = SearchBenchmark(options: options)
        let intakeBenchmark = IntakeBenchmark(options: options)

        // Persist each checkpoint the moment it completes, so an interrupted run keeps its data.
        let checkpointLog = CheckpointLog(outputDirectory: options.outputDirectory)
        checkpointLog.reset()

        var ingestedUUIDs: [UUID] = []
        var chunksInDatabase = 0
        var vectorsInIndex = 0
        var cumulativeIntakeSeconds: Double = 0
        var windowSamples: [Double] = []
        var windowChunks = 0
        var windowSeconds: Double = 0
        var checkpointIndex = 0
        var estimatedGlobalIndexWriteBytes: UInt64 = 0

        Console.heading("Intake and search across corpus sizes")
        Console.info("Growing to \(finalTarget) documents, measuring search at: \(reachableCheckpoints.map(String.init).joined(separator: ", "))")

        let progress = Console.Progress(total: finalTarget, label: "Ingesting")

        for (ordinal, document) in documents.prefix(finalTarget).enumerated() {
            do {
                let (_, duration) = try await timed {
                    try await database.createDocument(
                        uuid: document.uuid,
                        title: document.title,
                        description: document.description,
                        embeddableContent: document.chunks
                    )
                }

                ingestedUUIDs.append(document.uuid)
                chunksInDatabase += document.chunkCount
                vectorsInIndex += document.chunks.filter { $0.contentType == .text }.count
                cumulativeIntakeSeconds += duration.seconds
                windowSeconds += duration.seconds
                windowChunks += document.chunkCount
                windowSamples.append(duration.milliseconds)

                // Every insert rewrites the whole global index, so the write volume the storage layer
                // sees grows with the corpus. Tracking it explains the intake curve's shape.
                estimatedGlobalIndexWriteBytes += UInt64(vectorsInIndex * embedder.dimension * 4)

                results.intakeSeries.append(
                    IntakeSample(
                        ordinal: ordinal,
                        documentsInDatabase: ingestedUUIDs.count,
                        chunksInDatabase: chunksInDatabase,
                        chunkCount: document.chunkCount,
                        milliseconds: duration.milliseconds,
                        origin: document.origin
                    )
                )

                if options.verbose {
                    Console.info("[\(ordinal)] \(document.title) — \(document.chunkCount) chunks in \(fixed(duration.milliseconds, 1)) ms")
                }
            } catch {
                Console.warn("Failed to ingest '\(document.title)': \(error)")
            }

            progress.advance(
                ingestedUUIDs.count,
                detail: "\(chunksInDatabase) chunks, \(fixed(windowSamples.last ?? 0, 0)) ms/doc"
            )

            // MARK: Checkpoint
            while checkpointIndex < reachableCheckpoints.count,
                  ingestedUUIDs.count >= reachableCheckpoints[checkpointIndex] {
                progress.finish()
                checkpointIndex += 1

                Console.info("")
                Console.info("── Checkpoint: \(ingestedUUIDs.count) documents, \(chunksInDatabase) chunks, \(vectorsInIndex) vectors")

                let intakeStats = DurationStats(samplesInMilliseconds: windowSamples)
                Console.info("Intake in this window: mean \(fixed(intakeStats.meanMilliseconds, 1)) ms/doc, p99 \(fixed(intakeStats.p99Milliseconds, 1)) ms, \(fixed(Double(windowChunks) / max(windowSeconds, 0.0001), 1)) chunks/s")

                let warm = try await searchBenchmark.measureWarmSearch(
                    database: database,
                    embedder: embedder,
                    queries: queries,
                    nItems: 10
                )
                Console.info("Search (warm, nItems=10): p50 \(fixed(warm.overall.p50Milliseconds)) ms, p90 \(fixed(warm.overall.p90Milliseconds)) ms, p99 \(fixed(warm.overall.p99Milliseconds)) ms")

                let within = try await searchBenchmark.measureWithinDocumentSearch(
                    database: database,
                    documentIDs: ingestedUUIDs,
                    queries: queries,
                    nItems: 10
                )
                Console.info("Search (single document): p50 \(fixed(within.p50Milliseconds)) ms")

                // Release the warm instance so the cold measurement really does pay index load.
                database = nil
                let cold = try await searchBenchmark.measureColdSearch(
                    queries: Array(queries.prefix(5)),
                    nItems: 10,
                    makeDatabase: makeDatabase
                )
                database = try makeDatabase()
                Console.info("Search (cold open): mean \(fixed(cold.meanMilliseconds, 1)) ms, max \(fixed(cold.maxMilliseconds, 1)) ms")

                // GRDB runs the pool in WAL mode, which keeps -wal and -shm sidecars next to the
                // database file. All three are part of what the database costs on disk.
                let sqliteDirectory = sqliteURL.deletingLastPathComponent()
                let sqliteName = sqliteURL.lastPathComponent
                let sqliteBytes = ResourceUsage.fileSizeBytes(at: sqliteURL)
                    + ResourceUsage.fileSizeBytes(at: sqliteDirectory.appending(path: "\(sqliteName)-wal"))
                    + ResourceUsage.fileSizeBytes(at: sqliteDirectory.appending(path: "\(sqliteName)-shm"))
                let globalBytes = ResourceUsage.fileSizeBytes(at: globalIndexURL)
                let indexBytes = ResourceUsage.directorySizeBytes(at: indexDirectory)

                let report = CheckpointReport(
                    documentsInDatabase: ingestedUUIDs.count,
                    chunksInDatabase: chunksInDatabase,
                    vectorsInIndex: vectorsInIndex,
                    intakeStats: intakeStats,
                    intakeMillisecondsPerChunk: windowChunks > 0 ? (windowSeconds * 1_000) / Double(windowChunks) : 0,
                    intakeChunksPerSecond: windowSeconds > 0 ? Double(windowChunks) / windowSeconds : 0,
                    intakeDocumentsPerSecond: windowSeconds > 0 ? Double(windowSamples.count) / windowSeconds : 0,
                    cumulativeIntakeSeconds: cumulativeIntakeSeconds,
                    searchOverall: warm.overall,
                    searchByCategory: warm.byCategory,
                    queryEmbeddingStats: warm.queryEmbedding,
                    coldSearchStats: cold,
                    withinDocumentSearchStats: within,
                    meanResultCount: warm.meanResultCount,
                    sqliteBytes: sqliteBytes,
                    globalIndexBytes: globalBytes,
                    perDocumentIndexBytes: indexBytes > globalBytes ? indexBytes - globalBytes : 0,
                    indexFileCount: ResourceUsage.fileCount(in: indexDirectory),
                    totalDatabaseBytes: ResourceUsage.directorySizeBytes(at: bundleURL),
                    memoryFootprintBytes: ResourceUsage.memoryFootprintBytes(),
                    cumulativeGlobalIndexWriteBytes: estimatedGlobalIndexWriteBytes
                )
                results.checkpoints.append(report)
                checkpointLog.append(report)
                try? CSVWriter.writeIntakeSeries(results.intakeSeries, to: options.outputDirectory)

                Console.info("On disk: SQLite \(formatBytes(report.sqliteBytes)), global index \(formatBytes(report.globalIndexBytes)), per-document indices \(formatBytes(report.perDocumentIndexBytes)) across \(report.indexFileCount) files")
                Console.info("Process memory footprint: \(formatBytes(report.memoryFootprintBytes))")
                Console.info("Global index bytes rewritten so far: \(formatBytes(estimatedGlobalIndexWriteBytes))")

                windowSamples.removeAll(keepingCapacity: true)
                windowChunks = 0
                windowSeconds = 0
                Console.info("")
            }
        }

        progress.finish()

        // MARK: Final-size measurements
        if let last = results.checkpoints.last {
            Console.heading("Top-k sweep at \(last.documentsInDatabase) documents")
            results.topK = try await searchBenchmark.measureTopKSweep(
                database: database,
                embedder: embedder,
                queries: queries,
                documentsInDatabase: last.documentsInDatabase
            )

            Console.heading("Update and delete at \(last.documentsInDatabase) documents")
            let ingestedSet = Set(ingestedUUIDs)
            let candidates = documents.filter { ingestedSet.contains($0.uuid) }
            results.mutation = try await intakeBenchmark.measureMutations(
                database: database,
                candidates: candidates,
                documentsInDatabase: last.documentsInDatabase
            )
            if let mutation = results.mutation {
                Console.info("Update: mean \(fixed(mutation.updateStats.meanMilliseconds, 1)) ms, p99 \(fixed(mutation.updateStats.p99Milliseconds, 1)) ms")
                Console.info("Delete: mean \(fixed(mutation.deleteStats.meanMilliseconds, 1)) ms, p99 \(fixed(mutation.deleteStats.p99Milliseconds, 1)) ms")
            }
        }

        try? CSVWriter.writeIntakeSeries(results.intakeSeries, to: options.outputDirectory)

        database = nil
        return results
    }

    /// Fits a checkpoint measurement against the number of vectors in the index.
    ///
    /// Also refits with the smallest checkpoint dropped. With only a handful of checkpoints, the
    /// smallest one carries the most first-touch noise and can move the exponent far enough to change
    /// the conclusion, so both fits are reported and the interpretation is taken from whichever
    /// explains the data better.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func makeScalingFit(
        subject: String,
        checkpoints: [CheckpointReport],
        value: (CheckpointReport) -> Double
    ) -> ScalingFit? {
        let ordered = checkpoints.sorted { $0.vectorsInIndex < $1.vectorsInIndex }
        let points = ordered.map { (x: Double($0.vectorsInIndex), y: value($0)) }

        guard let full = fitPowerLaw(points: points) else { return nil }

        let trimmed = points.count >= 4 ? fitPowerLaw(points: Array(points.dropFirst())) : nil

        // Prefer whichever fit actually describes the data when reporting the shape of the curve.
        let preferred = (trimmed?.rSquared ?? 0) > full.rSquared ? trimmed! : full

        return ScalingFit(
            subject: subject,
            independentVariable: "vectors in index",
            exponent: full.exponent,
            coefficient: full.coefficient,
            rSquared: full.rSquared,
            pointCount: full.pointCount,
            exponentExcludingSmallest: trimmed?.exponent,
            rSquaredExcludingSmallest: trimmed?.rSquared,
            interpretation: interpret(exponent: preferred.exponent, subject: subject)
        )
    }

    /// Turns a fitted exponent into a plain-language statement.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func interpret(exponent: Double, subject: String) -> String {
        switch exponent {
        case ..<0.15:
            return "Effectively constant: \(subject) cost does not grow with corpus size over the measured range."
        case 0.15..<0.6:
            return "Sublinear: \(subject) cost grows more slowly than corpus size."
        case 0.6..<1.35:
            return "Linear: \(subject) cost grows in proportion to corpus size. Doubling the corpus roughly doubles it."
        case 1.35..<1.75:
            return "Superlinear: \(subject) cost grows faster than corpus size."
        default:
            return "Quadratic or worse: \(subject) cost grows with the square of corpus size. Doubling the corpus roughly quadruples it."
        }
    }
}

// MARK: - Summaries

extension BenchmarkRunner {
    /// Reduces the prepared corpus to the statistics worth reporting.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func summarize(_ corpus: CorpusBuilder.Result) -> CorpusSummary {
        let documents = corpus.documents
        let chunkCounts = documents.map(\.chunkCount).sorted()
        let totalChunks = chunkCounts.reduce(0, +)
        let totalCharacters = documents.reduce(0) { $0 + $1.textCharacters }

        var documentsByKind: [String: Int] = [:]
        var chunksByKind: [String: Int] = [:]
        for document in documents {
            documentsByKind[document.sourceKind, default: 0] += 1
            chunksByKind[document.sourceKind, default: 0] += document.chunkCount
        }

        // Count from the final document set rather than from what was digested: the corpus is trimmed
        // to the target document count, so the digested totals would overstate what was measured.
        return CorpusSummary(
            realDocuments: documents.count { $0.origin == .real },
            syntheticDocuments: documents.count { $0.origin == .synthetic },
            totalDocuments: documents.count,
            totalChunks: totalChunks,
            totalTextCharacters: totalCharacters,
            meanChunksPerDocument: documents.isEmpty ? 0 : Double(totalChunks) / Double(documents.count),
            medianChunksPerDocument: chunkCounts.isEmpty ? 0 : chunkCounts[chunkCounts.count / 2],
            maxChunksPerDocument: chunkCounts.last ?? 0,
            meanCharactersPerChunk: totalChunks == 0 ? 0 : Double(totalCharacters) / Double(totalChunks),
            documentsByKind: documentsByKind,
            chunksByKind: chunksByKind,
            skippedFileCount: corpus.skippedFiles.count
        )
    }

    /// Logs the corpus shape so a reader knows what the numbers were produced against.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func logCorpus(_ summary: CorpusSummary) {
        Console.info("\(summary.totalDocuments) documents (\(summary.realDocuments) real, \(summary.syntheticDocuments) synthetic), \(summary.totalChunks) chunks, \(summary.totalTextCharacters) characters of text.")
        Console.info("Chunks per document: mean \(fixed(summary.meanChunksPerDocument, 1)), median \(summary.medianChunksPerDocument), max \(summary.maxChunksPerDocument). Mean chunk \(fixed(summary.meanCharactersPerChunk, 0)) characters.")
        let kinds = summary.documentsByKind.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        Console.info("By format: \(kinds)")
    }

    /// Builds the digestion throughput report, ignoring files served from the chunk cache.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func digestionReport(from corpus: CorpusBuilder.Result) -> DigestionReport {
        let measured = corpus.digestMeasurements.filter { !$0.servedFromCache }
        let cached = corpus.digestMeasurements.count - measured.count

        var byKind: [String: [DigestMeasurement]] = [:]
        for measurement in measured {
            byKind[measurement.sourceKind, default: []].append(measurement)
        }

        let perKind = byKind
            .sorted { $0.value.count > $1.value.count }
            .map { kind, entries -> DigestionReport.PerKind in
                let stats = DurationStats(samplesInMilliseconds: entries.map(\.milliseconds))
                let totalSeconds = stats.totalMilliseconds / 1_000
                let totalMegabytes = Double(entries.reduce(0) { $0 + $1.sourceBytes }) / 1_048_576
                let totalChunks = entries.reduce(0) { $0 + $1.chunkCount }
                return DigestionReport.PerKind(
                    kind: kind,
                    files: entries.count,
                    stats: stats,
                    megabytesPerSecond: totalSeconds > 0 ? totalMegabytes / totalSeconds : 0,
                    chunksPerSecond: totalSeconds > 0 ? Double(totalChunks) / totalSeconds : 0
                )
            }

        return DigestionReport(
            measuredFiles: measured.count,
            cachedFiles: cached,
            overall: DurationStats(samplesInMilliseconds: measured.map(\.milliseconds)),
            byKind: perKind
        )
    }
}
