//
//  IrisBenchmark.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import ArgumentParser
import Foundation

/// Entry point for the IrisSearch benchmark executable.
///
/// Measures what it costs to put documents into `IrisDB` and to get them back out, across corpus
/// sizes spanning the range a research library actually occupies.
///
/// - Authored by: Claude Opus 5 (Anthropic)
@main
struct IrisBenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "IrisBenchmark",
        abstract: "Measures IrisSearch intake and search performance across corpus sizes.",
        discussion: """
        Grows a single database through the configured document counts, measuring intake as it goes and \
        running the full query suite at each checkpoint. Because intake and search are measured on the \
        same growing database, both curves share one comparable x-axis.

        Always build with -c release. A debug build is several times slower and the tool will say so.

        Cost warning: FaissIndex rewrites the entire global index file on every insert, so the bytes a \
        run writes grow with the square of the document count. Doubling the top checkpoint roughly \
        quadruples the disk written. Raise --checkpoints deliberately.

        EXAMPLES

          Quick run against a folder of documents:
            swift run -c release IrisBenchmark --corpus ~/Documents/Papers

          Isolate the database from the embedding model:
            swift run -c release IrisBenchmark --corpus ~/Papers --embedder hash

          Measure the model the app actually ships:
            swift run -c release IrisBenchmark --corpus ~/Papers \\
              --embedder coreml --coreml-model ~/Library/.../bge_small_en_v1.5
        """
    )

    // MARK: Corpus

    @Option(
        name: .customLong("corpus"),
        help: ArgumentHelp(
            "Root directory of source documents. Repeat the flag for multiple roots.",
            valueName: "path"
        )
    )
    var corpusRoots: [String] = []

    @Option(name: .customLong("context-size"), help: "Chunk size passed to digesters.")
    var contextSize: Int = 512

    @Flag(name: .customLong("include-images"), help: "Keep PDF page images as document pieces. They are never embedded.")
    var includeImages = false

    @Flag(name: .customLong("no-synthetic"), help: "Stop at the number of real documents found instead of padding the corpus with recombined synthetic documents.")
    var noSynthetic = false

    @Flag(name: .customLong("no-cache"), help: "Re-digest every file instead of reading the chunk cache.")
    var noCache = false

    @Option(name: .customLong("cache"), help: ArgumentHelp("Digested chunk cache directory.", valueName: "path"))
    var cacheDirectory: String?

    // MARK: Scale

    @Option(
        name: .customLong("checkpoints"),
        parsing: .upToNextOption,
        help: "Document counts to measure search at."
    )
    var checkpoints: [Int] = [100, 250, 500, 1_000, 2_000]

    @Option(name: .customLong("max-documents"), help: "Ceiling on ingested documents. Defaults to the largest checkpoint.")
    var maxDocuments: Int?

    // MARK: Embedding

    // EmbedderKind is CaseIterable and ExpressibleByArgument, so ArgumentParser lists the valid
    // values in --help on its own.
    @Option(name: .customLong("embedder"), help: "Embedding provider.")
    var embedder: EmbedderKind = .naturalLanguage

    @Option(
        name: .customLong("coreml-model"),
        help: ArgumentHelp("Model directory containing a .mlmodelc, vocab.txt and config.json. Required for --embedder coreml.", valueName: "path")
    )
    var coreMLModel: String?

    @Option(name: .customLong("hash-dimension"), help: "Vector width for the hash embedder.")
    var hashDimension: Int = 512

    // MARK: Search

    @Option(name: .customLong("queries-per-category"), help: "Generated queries per query category.")
    var queriesPerCategory: Int = 6

    @Option(name: .customLong("search-iterations"), help: "Timed repetitions per query.")
    var searchIterations: Int = 12

    @Option(name: .customLong("search-warmup"), help: "Untimed repetitions per query, run before the timed ones.")
    var searchWarmup: Int = 3

    @Option(
        name: .customLong("top-k"),
        parsing: .upToNextOption,
        help: "nItems values swept at the final checkpoint."
    )
    var topK: [Int] = [5, 10, 25, 50]

    // MARK: Mutation

    @Option(
        name: .customLong("concurrency"),
        parsing: .upToNextOption,
        help: "Concurrency levels for the parallel intake phase."
    )
    var concurrency: [Int] = [1, 2, 4, 8]

    @Flag(name: .customLong("no-concurrency"), help: "Skip the parallel intake phase entirely.")
    var noConcurrency = false

    @Option(name: .customLong("concurrency-documents"), help: "Documents ingested per concurrency level.")
    var concurrencyDocuments: Int = 150

    @Option(name: .customLong("mutation-documents"), help: "Documents sampled for update and delete timing.")
    var mutationDocuments: Int = 50

    // MARK: Output

    @Option(name: .customLong("output"), help: ArgumentHelp("Results directory.", valueName: "path"))
    var outputDirectory: String?

    @Option(name: .customLong("working-directory"), help: ArgumentHelp("Where the benchmark database is built.", valueName: "path"))
    var workingDirectory: String?

    @Option(name: .customLong("seed"), help: "Seed for corpus ordering, synthesis and query sampling.")
    var seed: Int = 0xC0FFEE

    @Flag(name: .shortAndLong, help: "Log every ingested document as it lands.")
    var verbose = false

    /// Rejects argument combinations that cannot produce a run, before any work starts.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func validate() throws {
        guard !corpusRoots.isEmpty else {
            throw ValidationError("At least one --corpus <path> is required.")
        }

        if embedder == .coreml, coreMLModel == nil {
            throw ValidationError("--embedder coreml requires --coreml-model <path to a directory containing a .mlmodelc, vocab.txt and config.json>.")
        }

        guard !checkpoints.isEmpty else {
            throw ValidationError("--checkpoints needs at least one document count.")
        }

        guard checkpoints.allSatisfy({ $0 > 0 }) else {
            throw ValidationError("--checkpoints values must be positive.")
        }

        guard contextSize > 0 else {
            throw ValidationError("--context-size must be positive.")
        }

        guard searchIterations > 0 else {
            throw ValidationError("--search-iterations must be at least 1.")
        }

        if let maxDocuments, maxDocuments <= 0 {
            throw ValidationError("--max-documents must be positive.")
        }
    }

    /// Builds the run configuration from the parsed arguments.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func makeOptions() -> BenchmarkOptions {
        var options = BenchmarkOptions()

        options.corpusRoots = corpusRoots.map { URL(fileURLWithPath: $0).standardizedFileURL }
        options.contextSize = contextSize
        options.includeImages = includeImages
        options.allowSynthetic = !noSynthetic
        options.useCache = !noCache
        if let cacheDirectory { options.cacheDirectory = URL(fileURLWithPath: cacheDirectory) }

        options.checkpoints = checkpoints.sorted()
        options.maxDocuments = maxDocuments

        options.embedderKind = embedder
        options.coreMLModelDirectory = coreMLModel.map { URL(fileURLWithPath: $0) }
        options.hashDimension = hashDimension

        options.queriesPerCategory = queriesPerCategory
        options.searchIterations = searchIterations
        options.searchWarmupIterations = searchWarmup
        options.topKSweep = topK

        options.intakeConcurrencySweep = noConcurrency ? [] : concurrency
        options.intakeConcurrencyDocuments = concurrencyDocuments
        options.mutationDocuments = mutationDocuments

        if let outputDirectory { options.outputDirectory = URL(fileURLWithPath: outputDirectory) }
        if let workingDirectory { options.workingDirectory = URL(fileURLWithPath: workingDirectory) }
        options.randomSeed = UInt64(bitPattern: Int64(seed))
        options.verbose = verbose

        return options
    }

    /// Runs the benchmark and writes its artifacts.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func run() async throws {
        let options = makeOptions()

        // The benchmark database is large and disposable. Always clean it up, including after a failure.
        defer { try? FileManager.default.removeItem(at: options.workingDirectory) }

        try FileManager.default.createDirectory(at: options.workingDirectory, withIntermediateDirectories: true)

        let report = try await BenchmarkRunner(options: options).run()
        try ReportWriter(report: report, outputDirectory: options.outputDirectory).write()
    }
}
