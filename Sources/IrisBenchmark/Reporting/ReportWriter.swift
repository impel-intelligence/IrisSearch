//
//  ReportWriter.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation

/// Writes the per-document intake series so the intake curve can be plotted.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum CSVWriter {
    /// Emits `intake-series.csv`, one row per ingested document.
    ///
    /// The checkpoint tables aggregate this, but the raw series is what shows whether per-document
    /// cost drifts upward as the corpus grows, and how noisy it is.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func writeIntakeSeries(_ samples: [BenchmarkRunner.IntakeSample], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines = ["ordinal,documents_in_database,chunks_in_database,chunk_count,milliseconds,origin"]
        for sample in samples {
            lines.append("\(sample.ordinal),\(sample.documentsInDatabase),\(sample.chunksInDatabase),\(sample.chunkCount),\(fixed(sample.milliseconds, 3)),\(sample.origin.rawValue)")
        }

        try lines.joined(separator: "\n").write(
            to: directory.appending(path: "intake-series.csv"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// Appends each checkpoint to disk as soon as it completes.
///
/// A full run takes tens of minutes and only writes `results.json` at the very end, so an interruption
/// — a closed laptop, a cancelled process — would otherwise throw away everything measured so far.
/// This streams each checkpoint out as a JSON line the moment it is finished.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct CheckpointLog {
    let outputDirectory: URL

    private var fileURL: URL { outputDirectory.appending(path: "checkpoints.jsonl") }

    /// Removes any log left behind by a previous run.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func reset() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Appends one checkpoint. Failures are ignored: this is a safety net, not the primary artifact.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func append(_ checkpoint: CheckpointReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(checkpoint) else { return }
        data.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// Renders the report to the terminal, to JSON and to Markdown.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct ReportWriter {
    let report: BenchmarkReport
    let outputDirectory: URL

    /// Writes every artifact and prints the summary tables.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func write() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: outputDirectory.appending(path: "results.json"))

        let markdown = renderMarkdown()
        try markdown.write(to: outputDirectory.appending(path: "summary.md"), atomically: true, encoding: .utf8)

        printSummary()

        Console.heading("Artifacts")
        Console.info("results.json       — full machine readable results")
        Console.info("summary.md         — the tables below, as Markdown")
        Console.info("intake-series.csv  — per-document intake timings")
        Console.info("Written to \(outputDirectory.path(percentEncoded: false))")
    }
}

// MARK: - Tables

extension ReportWriter {
    /// The scaling table: how intake and search behave as the corpus grows.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func scalingTable() -> TextTable {
        var table = TextTable(headers: [
            "documents", "chunks", "intake ms/doc", "intake chunks/s",
            "search p50 ms", "search p90 ms", "search p99 ms", "cold ms", "in-doc p50 ms", "db size"
        ])

        for checkpoint in report.checkpoints {
            table.append([
                String(checkpoint.documentsInDatabase),
                String(checkpoint.chunksInDatabase),
                fixed(checkpoint.intakeStats.meanMilliseconds, 1),
                fixed(checkpoint.intakeChunksPerSecond, 1),
                fixed(checkpoint.searchOverall.p50Milliseconds, 2),
                fixed(checkpoint.searchOverall.p90Milliseconds, 2),
                fixed(checkpoint.searchOverall.p99Milliseconds, 2),
                fixed(checkpoint.coldSearchStats.meanMilliseconds, 1),
                fixed(checkpoint.withinDocumentSearchStats.p50Milliseconds, 2),
                formatBytes(checkpoint.totalDatabaseBytes)
            ])
        }
        return table
    }

    /// Search latency broken down by query shape at each corpus size.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func categoryTable() -> TextTable {
        let categories = QueryCategory.allCases
        var table = TextTable(headers: ["documents"] + categories.map { "\($0.displayName) p50" })

        for checkpoint in report.checkpoints {
            var row = [String(checkpoint.documentsInDatabase)]
            for category in categories {
                if let stats = checkpoint.searchByCategory[category.rawValue] {
                    row.append(fixed(stats.p50Milliseconds, 2))
                } else {
                    row.append("—")
                }
            }
            table.append(row)
        }
        return table
    }

    /// Where the time inside a search actually goes.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func attributionTable() -> TextTable {
        var table = TextTable(headers: [
            "documents", "search p50 ms", "query embedding p50 ms", "embedding share", "retrieval p50 ms"
        ])

        for checkpoint in report.checkpoints {
            let search = checkpoint.searchOverall.p50Milliseconds
            let embedding = checkpoint.queryEmbeddingStats.p50Milliseconds
            let share = search > 0 ? (embedding / search) * 100 : 0
            table.append([
                String(checkpoint.documentsInDatabase),
                fixed(search, 2),
                fixed(embedding, 2),
                "\(fixed(share, 0))%",
                fixed(max(0, search - embedding), 2)
            ])
        }
        return table
    }

    /// Storage growth per corpus size.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func storageTable() -> TextTable {
        var table = TextTable(headers: [
            "documents", "vectors", "SQLite", "global index", "per-doc indices", "index files",
            "total", "process memory", "index bytes rewritten"
        ])

        for checkpoint in report.checkpoints {
            table.append([
                String(checkpoint.documentsInDatabase),
                String(checkpoint.vectorsInIndex),
                formatBytes(checkpoint.sqliteBytes),
                formatBytes(checkpoint.globalIndexBytes),
                formatBytes(checkpoint.perDocumentIndexBytes),
                String(checkpoint.indexFileCount),
                formatBytes(checkpoint.totalDatabaseBytes),
                formatBytes(checkpoint.memoryFootprintBytes),
                formatBytes(checkpoint.cumulativeGlobalIndexWriteBytes)
            ])
        }
        return table
    }

    /// Digestion throughput per source format.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func digestionTable() -> TextTable {
        var table = TextTable(headers: ["format", "files", "mean ms", "p99 ms", "MB/s", "chunks/s"])
        for kind in report.digestion.byKind {
            table.append([
                kind.kind,
                String(kind.files),
                fixed(kind.stats.meanMilliseconds, 1),
                fixed(kind.stats.p99Milliseconds, 1),
                fixed(kind.megabytesPerSecond, 2),
                fixed(kind.chunksPerSecond, 1)
            ])
        }
        return table
    }

    /// Top-k sensitivity at the largest measured corpus size.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func topKTable() -> TextTable {
        var table = TextTable(headers: ["nItems", "p50 ms", "p90 ms", "p99 ms", "mean results"])
        for entry in report.topK {
            table.append([
                String(entry.nItems),
                fixed(entry.stats.p50Milliseconds, 2),
                fixed(entry.stats.p90Milliseconds, 2),
                fixed(entry.stats.p99Milliseconds, 2),
                fixed(entry.meanResultCount, 1)
            ])
        }
        return table
    }

    /// Parallel intake throughput.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func concurrencyTable() -> TextTable {
        var table = TextTable(headers: ["concurrency", "documents", "wall clock s", "docs/s", "chunks/s", "speedup"])
        for entry in report.concurrency {
            table.append([
                String(entry.concurrency),
                String(entry.documents),
                fixed(entry.wallClockSeconds, 2),
                fixed(entry.documentsPerSecond, 2),
                fixed(entry.chunksPerSecond, 1),
                "\(fixed(entry.speedupVersusSerial, 2))×"
            ])
        }
        return table
    }
}

// MARK: - Console summary

extension ReportWriter {
    /// Prints every table to the terminal.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func printSummary() {
        Console.heading("Results: intake and search versus corpus size")
        print(scalingTable().rendered())

        Console.heading("Search latency by query shape (p50, ms)")
        print(categoryTable().rendered())

        Console.heading("Where search time goes")
        print(attributionTable().rendered())

        Console.heading("Storage and memory")
        print(storageTable().rendered())

        if !report.digestion.byKind.isEmpty {
            Console.heading("Digestion throughput by format")
            print(digestionTable().rendered())
        }

        if !report.topK.isEmpty {
            Console.heading("Results requested versus latency")
            print(topKTable().rendered())
        }

        if !report.concurrency.isEmpty {
            Console.heading("Parallel intake")
            print(concurrencyTable().rendered())
        }

        Console.heading("Scaling versus vectors in index")
        for fit in [report.intakeScaling, report.searchScaling].compactMap({ $0 }) {
            Console.info("\(fit.subject): ≈ \(fixed(fit.coefficient, 6)) × vectors^\(fixed(fit.exponent, 2)) ms  (R²=\(fixed(fit.rSquared, 3)), \(fit.pointCount) points)")
            if let trimmed = fit.exponentExcludingSmallest, let r2 = fit.rSquaredExcludingSmallest {
                Console.info("  excluding smallest checkpoint: exponent \(fixed(trimmed, 2)) (R²=\(fixed(r2, 3)))")
            }
            Console.info("  \(fit.interpretation)")
        }

        if let mutation = report.mutation {
            Console.heading("Mutation at \(mutation.documentsInDatabase) documents")
            Console.info("Update: mean \(fixed(mutation.updateStats.meanMilliseconds, 1)) ms, p50 \(fixed(mutation.updateStats.p50Milliseconds, 1)) ms, p99 \(fixed(mutation.updateStats.p99Milliseconds, 1)) ms")
            Console.info("Delete: mean \(fixed(mutation.deleteStats.meanMilliseconds, 1)) ms, p50 \(fixed(mutation.deleteStats.p50Milliseconds, 1)) ms, p99 \(fixed(mutation.deleteStats.p99Milliseconds, 1)) ms")
        }

        Console.heading("Run")
        Console.info("Total wall clock: \(formatSeconds(report.totalRunSeconds))")
    }
}

// MARK: - Markdown

extension ReportWriter {
    /// The limits of what this run can support, stated explicitly.
    ///
    /// A benchmark that does not say what it fails to measure invites conclusions it cannot carry, so
    /// the conditions that make these numbers optimistic are listed next to them rather than omitted.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func renderCaveats() -> String {
        var notes: [String] = []

        if report.host.swiftBuildConfiguration == "debug" {
            notes.append("**This was a debug build.** Every number here is several times slower than a release build. Rerun with `swift run -c release IrisBenchmark`.")
        }

        if report.configuration.embedderKind == .hash {
            notes.append("""
            **The hash embedder was used, not a real model.** Its vectors carry no semantic meaning, so
            these numbers describe the storage and retrieval layers rather than end-to-end search quality
            or cost. Two consequences make the search figures optimistic: query embedding is effectively
            free, where a real provider costs milliseconds per query; and because the hashed vectors
            rarely clear `IrisDB.search`'s `semanticCutoff` of 0.6, fewer candidates survive to be
            hydrated out of SQLite than a real embedding would produce. Compare against a run with
            `--embedder nl` before quoting a search latency.
            """)
        }

        if report.corpus.syntheticDocuments > 0 {
            let share = Double(report.corpus.syntheticDocuments) / Double(report.corpus.totalDocuments) * 100
            notes.append("""
            **\(fixed(share, 0))% of the corpus is synthetic** (\(report.corpus.syntheticDocuments) of
            \(report.corpus.totalDocuments) documents). Synthetic documents are contiguous runs of chunks
            resampled from the real corpus, so chunk lengths, vocabulary and per-document chunk counts
            match the real material. What they do not reproduce is novelty: chunks recur across documents,
            which collides identical vectors in the FAISS index and inflates the document frequencies BM25
            sees. That changes which results come back, not what retrieval costs.
            """)
        }

        if !report.configuration.includeImages {
            notes.append("""
            **PDF page images were excluded.** `PDFDigester` renders every page to JPEG alongside the
            extracted text. Those pieces are stored in SQLite but never embedded, so they inflate the
            database without participating in search. Rerun with `--include-images` to measure the
            storage cost the app actually pays today.
            """)
        }

        notes.append("""
        **Cold search is a floor, not a worst case.** The cold measurement opens a fresh `IrisDB` so it
        pays migration checks, connection pool setup and full FAISS index deserialization — but the
        operating system's file cache still holds the index file. A genuine cold boot, with the file
        evicted, is slower.
        """)

        notes.append("""
        **Fitted exponents describe the measured range only.** They come from a least-squares fit over
        the checkpoint rows, which top out at \(report.checkpoints.last?.documentsInDatabase ?? 0)
        documents. Extrapolating an order of magnitude past that is not supported by this data.
        """)

        return (["## Caveats", ""] + notes.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }).joined(separator: "\n")
    }

    /// The full report as Markdown, suitable for pasting into a PR or a design document.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func renderMarkdown() -> String {
        var sections: [String] = []

        let formatter = ISO8601DateFormatter()

        sections.append("""
        # IrisSearch benchmark

        Generated \(formatter.string(from: report.host.timestamp)) — run took \(formatSeconds(report.totalRunSeconds)).

        ## Environment

        | | |
        | --- | --- |
        | CPU | \(report.host.cpuModel) (\(report.host.logicalCores) logical cores) |
        | Memory | \(formatBytes(report.host.physicalMemoryBytes)) |
        | OS | \(report.host.operatingSystem) |
        | Build | \(report.host.swiftBuildConfiguration) |
        | Embedder | \(report.configuration.embedder) |
        | Chunk size | \(report.configuration.contextSize) characters |
        | Seed | \(report.configuration.randomSeed) |

        ## Corpus

        | | |
        | --- | --- |
        | Documents | \(report.corpus.totalDocuments) (\(report.corpus.realDocuments) real, \(report.corpus.syntheticDocuments) synthetic) |
        | Chunks | \(report.corpus.totalChunks) |
        | Text | \(report.corpus.totalTextCharacters) characters |
        | Chunks per document | mean \(fixed(report.corpus.meanChunksPerDocument, 1)), median \(report.corpus.medianChunksPerDocument), max \(report.corpus.maxChunksPerDocument) |
        | Mean chunk | \(fixed(report.corpus.meanCharactersPerChunk, 0)) characters |
        | Formats | \(report.corpus.documentsByKind.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")) |
        | PDF page images | \(report.configuration.includeImages ? "included" : "excluded") |
        """)

        sections.append("""
        ## Intake and search versus corpus size

        \(scalingTable().markdown())

        `intake ms/doc` is the mean cost of `IrisDB.createDocument` for the documents ingested since the
        previous row. `search` columns are warm `IrisDB.search(query:nItems:)` at `nItems = 10`, pooled
        across every query shape. `cold ms` is the first search against a newly opened `IrisDB`, which
        pays FAISS index deserialization. `in-doc p50` is `search(within:)`.
        """)

        sections.append("""
        ## Search latency by query shape (p50, ms)

        \(categoryTable().markdown())

        The full-text half of the pipeline uses `FTS5Pattern(matchingAllTokensIn:)`, which is conjunctive.
        Single common terms hit long postings lists; whole sentences usually match nothing and leave the
        vector index to carry the query. These are different workloads and are not meaningfully averaged.
        """)

        sections.append("""
        ## Where search time goes

        \(attributionTable().markdown())

        `query embedding` is the isolated cost of turning the query text into a vector with the same
        provider, measured outside the database. Whatever is left is retrieval: FAISS, FTS5, GRDB
        hydration and rank fusion.
        """)

        sections.append("""
        ## Storage and memory

        \(storageTable().markdown())

        One FAISS index file is written per document alongside the global index, so `index files` grows
        with the corpus.

        `index bytes rewritten` is the cumulative volume the global index has been written with since the
        first insert. `FaissIndex.add(pieces:to:)` saves the entire global index after every document, so
        this is quadratic in document count — it is both the mechanism behind the intake curve and real
        write amplification against the user's disk.
        """)

        if !report.digestion.byKind.isEmpty {
            sections.append("""
            ## Digestion throughput by format

            \(digestionTable().markdown())

            Digestion belongs to the `Digester` module rather than the search database, but it is the
            first half of what a user experiences as adding a document. \(report.digestion.cachedFiles) of
            \(report.digestion.measuredFiles + report.digestion.cachedFiles) files were served from the
            chunk cache and are excluded here.
            """)
        }

        if !report.topK.isEmpty {
            sections.append("""
            ## Results requested versus latency

            \(topKTable().markdown())

            Measured at \(report.topK.first?.documentsInDatabase ?? 0) documents.
            """)
        }

        if !report.concurrency.isEmpty {
            sections.append("""
            ## Parallel intake

            \(concurrencyTable().markdown())

            `IrisDB` is an actor and funnels writes through a single GRDB writer, so speedup is bounded by
            the share of intake that happens before the write — principally embedding.
            """)
        }

        var scaling = ["## Scaling", ""]
        scaling.append("| measurement | fit | exponent | R² | exponent excl. smallest | R² excl. smallest |")
        scaling.append("| --- | --- | --- | --- | --- | --- |")
        for fit in [report.intakeScaling, report.searchScaling].compactMap({ $0 }) {
            let trimmedExponent = fit.exponentExcludingSmallest.map { fixed($0, 2) } ?? "—"
            let trimmedR2 = fit.rSquaredExcludingSmallest.map { fixed($0, 3) } ?? "—"
            scaling.append("| \(fit.subject) | `\(fixed(fit.coefficient, 6)) × vectors^\(fixed(fit.exponent, 2))` ms | \(fixed(fit.exponent, 2)) | \(fixed(fit.rSquared, 3)) | \(trimmedExponent) | \(trimmedR2) |")
        }
        scaling.append("")
        for fit in [report.intakeScaling, report.searchScaling].compactMap({ $0 }) {
            scaling.append("- **\(fit.subject)**: \(fit.interpretation)")
        }
        scaling.append("")
        scaling.append("""
        Cost is fitted against vectors in the index, not documents. Documents in this corpus range from a
        single chunk to \(report.corpus.maxChunksPerDocument), so document count is a noisy proxy; the FAISS
        scan and the FTS5 postings lists both grow with chunks.

        `R²` is the goodness of fit on the log-log transform. A low value means the exponent does not
        describe the data and should not be quoted. The second fit drops the smallest checkpoint, which is
        the one most exposed to first-touch effects — page cache, allocator growth, lazily initialized
        library state. Where the two disagree, the interpretation follows whichever fits better.

        Exponents describe the measured range only. Extrapolating an order of magnitude past the largest
        checkpoint is not supported by this data.
        """)
        sections.append(scaling.joined(separator: "\n"))

        if let mutation = report.mutation {
            sections.append("""
            ## Mutation at \(mutation.documentsInDatabase) documents

            | operation | mean ms | p50 ms | p99 ms | samples |
            | --- | --- | --- | --- | --- |
            | update | \(fixed(mutation.updateStats.meanMilliseconds, 1)) | \(fixed(mutation.updateStats.p50Milliseconds, 1)) | \(fixed(mutation.updateStats.p99Milliseconds, 1)) | \(mutation.updateStats.count) |
            | delete | \(fixed(mutation.deleteStats.meanMilliseconds, 1)) | \(fixed(mutation.deleteStats.p50Milliseconds, 1)) | \(fixed(mutation.deleteStats.p99Milliseconds, 1)) | \(mutation.deleteStats.count) |
            """)
        }

        sections.append(renderCaveats())

        sections.append("""
        ## Queries used

        \(QueryCategory.allCases.map { category -> String in
            let matching = report.configuration.queries.filter { $0.category == category }
            guard !matching.isEmpty else { return "" }
            return "**\(category.displayName)**\n" + matching.map { "- `\($0.text.replacingOccurrences(of: "`", with: "'"))`" }.joined(separator: "\n")
        }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        """)

        return sections.joined(separator: "\n\n")
    }
}
