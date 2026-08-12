//
//  Corpus.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import CryptoKit
import Digester
import Foundation
import IrisCommon
import UniformTypeIdentifiers

/// Where a benchmark document's content came from.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum DocumentOrigin: String, Codable, Sendable {
    /// Digested straight out of a file in the corpus.
    case real
    /// Assembled by recombining chunks drawn from real documents, to reach corpus sizes the source
    /// material cannot cover on its own.
    case synthetic
}

/// A document that has been digested into chunks and is ready to hand to `IrisDB.createDocument`.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct PreparedDocument: Sendable {
    let uuid: UUID
    let title: String
    let description: String
    let chunks: [EmbeddableContent]
    let origin: DocumentOrigin
    /// The file extension the content originally came from, used to break results down by format.
    let sourceKind: String
    /// Size of the source file on disk. Zero for synthetic documents.
    let sourceBytes: Int
    /// Total characters across all text chunks.
    let textCharacters: Int

    var chunkCount: Int { chunks.count }
}

/// Timing for digesting one real file.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct DigestMeasurement: Sendable {
    let sourceKind: String
    let sourceBytes: Int
    let chunkCount: Int
    let milliseconds: Double
    let servedFromCache: Bool
}

/// Discovers, digests and scales the benchmark corpus.
///
/// Digestion of a large PDF corpus takes minutes, and the same corpus is reused across runs while
/// tuning the database, so results are cached on disk keyed by file identity and chunking parameters.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct CorpusBuilder {
    let options: BenchmarkOptions

    /// The digested corpus plus the digestion timings gathered while producing it.
    struct Result: Sendable {
        let documents: [PreparedDocument]
        let digestMeasurements: [DigestMeasurement]
        let realDocumentCount: Int
        let syntheticDocumentCount: Int
        let skippedFiles: [String]
    }

    /// Walks the corpus roots, digests everything supported, then pads with synthetic documents until
    /// the target document count is reached.
    ///
    /// - Returns: The prepared corpus and per-file digestion timings.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func build() async throws -> Result {
        let files = try discoverFiles()
        Console.info("Discovered \(files.count) digestible files across \(options.corpusRoots.count) corpus root(s).")

        if options.useCache {
            try FileManager.default.createDirectory(at: options.cacheDirectory, withIntermediateDirectories: true)
        }

        var documents: [PreparedDocument] = []
        var measurements: [DigestMeasurement] = []
        var skipped: [String] = []

        let progress = Console.Progress(total: files.count, label: "Digesting corpus")

        for (index, file) in files.enumerated() {
            do {
                let (chunks, milliseconds, cached) = try await digest(file: file)
                let usableChunks = options.includeImages ? chunks : chunks.filter { $0.contentType == .text }

                guard !usableChunks.isEmpty else {
                    skipped.append("\(file.url.lastPathComponent): produced no usable chunks")
                    progress.advance(index + 1)
                    continue
                }

                let renumbered = renumber(usableChunks)
                documents.append(
                    PreparedDocument(
                        uuid: UUID(),
                        title: uniqueTitle(for: file.url, index: index),
                        description: description(for: file.url, chunks: renumbered),
                        chunks: renumbered,
                        origin: .real,
                        sourceKind: file.url.pathExtension.lowercased(),
                        sourceBytes: file.byteSize,
                        textCharacters: renumbered.reduce(0) { $0 + ($1.textContent?.count ?? 0) }
                    )
                )
                measurements.append(
                    DigestMeasurement(
                        sourceKind: file.url.pathExtension.lowercased(),
                        sourceBytes: file.byteSize,
                        chunkCount: renumbered.count,
                        milliseconds: milliseconds,
                        servedFromCache: cached
                    )
                )
            } catch {
                skipped.append("\(file.url.lastPathComponent): \(error)")
            }
            progress.advance(index + 1)
        }

        progress.finish()

        // The chunk cache makes repeat runs fast, but it also means a warm cache would leave the run
        // with no digestion timings at all. Re-digest a stratified sample with the cache bypassed so
        // every run reports throughput for every format it contains.
        let freshCount = measurements.count { !$0.servedFromCache }
        if options.useCache, freshCount < files.count {
            measurements.append(contentsOf: await measureDigestionSample(from: files, alreadyMeasured: measurements))
        }

        if !skipped.isEmpty {
            Console.warn("Skipped \(skipped.count) file(s). First few reasons:")
            for reason in skipped.prefix(5) {
                Console.warn("  \(reason)")
            }
        }

        guard !documents.isEmpty else {
            throw CorpusError.emptyCorpus
        }

        let realCount = documents.count
        Console.info("Digested \(realCount) documents into \(documents.reduce(0) { $0 + $1.chunkCount }) chunks. Skipped \(skipped.count).")

        // Shuffle deterministically so checkpoints see a representative mix of formats and lengths
        // rather than every PDF first and every Markdown file last.
        var generator = SeededGenerator(seed: options.randomSeed)
        documents.shuffle(using: &generator)

        var syntheticCount = 0
        let target = options.targetDocumentCount

        if documents.count < target {
            if options.allowSynthetic {
                let synthetic = synthesize(
                    count: target - documents.count,
                    from: documents,
                    generator: &generator
                )
                syntheticCount = synthetic.count
                documents.append(contentsOf: synthetic)
                Console.info("Padded corpus with \(syntheticCount) synthetic documents recombined from real chunks to reach \(target).")
            } else {
                Console.warn("Corpus has \(documents.count) real documents but the run targets \(target). Synthesis is disabled, so checkpoints above \(documents.count) will be skipped.")
            }
        } else if documents.count > target {
            documents = Array(documents.prefix(target))
        }

        return Result(
            documents: documents,
            digestMeasurements: measurements,
            realDocumentCount: realCount,
            syntheticDocumentCount: syntheticCount,
            skippedFiles: skipped
        )
    }
}

// MARK: - Discovery

extension CorpusBuilder {
    enum CorpusError: Error, CustomStringConvertible {
        case emptyCorpus

        var description: String {
            switch self {
            case .emptyCorpus:
                return "No documents could be digested from the supplied corpus roots."
            }
        }
    }

    struct SourceFile: Sendable {
        let url: URL
        let type: UTType
        let byteSize: Int
        let modificationDate: Date
    }

    /// Enumerates every file under the corpus roots that a registered digester can handle.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func discoverFiles() throws -> [SourceFile] {
        var files: [SourceFile] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for root in options.corpusRoots {
            guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
                Console.warn("Corpus root does not exist, skipping: \(root.path(percentEncoded: false))")
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { continue }
                // Only keep files a registered digester actually claims.
                guard (try? DigesterFactory.digester(for: type)) != nil else { continue }

                files.append(
                    SourceFile(
                        url: url,
                        type: type,
                        byteSize: values.fileSize ?? 0,
                        modificationDate: values.contentModificationDate ?? .distantPast
                    )
                )
            }
        }

        // Stable ordering keeps the cache keys and the seeded shuffle reproducible across runs.
        return files.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }
}

// MARK: - Digestion and caching

extension CorpusBuilder {
    /// Re-digests a sample of files with the chunk cache bypassed, purely to time digestion.
    ///
    /// Files are sampled evenly across each format so a corpus dominated by one extension still yields
    /// a timing for the others. The chunks produced are thrown away — the corpus was already built from
    /// the cache — so this only costs time, not correctness.
    ///
    /// - Parameters:
    ///   - files: Every discovered source file.
    ///   - alreadyMeasured: Measurements gathered so far, used to skip formats already timed fresh.
    /// - Returns: Additional measurements, all with `servedFromCache` false.
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func measureDigestionSample(
        from files: [SourceFile],
        alreadyMeasured: [DigestMeasurement]
    ) async -> [DigestMeasurement] {
        let sampleSizePerFormat = 12

        var byFormat: [String: [SourceFile]] = [:]
        for file in files {
            byFormat[file.url.pathExtension.lowercased(), default: []].append(file)
        }

        var freshPerFormat: [String: Int] = [:]
        for measurement in alreadyMeasured where !measurement.servedFromCache {
            freshPerFormat[measurement.sourceKind, default: 0] += 1
        }

        var selected: [SourceFile] = []
        for (format, group) in byFormat {
            let needed = sampleSizePerFormat - (freshPerFormat[format] ?? 0)
            guard needed > 0 else { continue }

            // Even spacing across the group rather than the first N, so the sample is not biased
            // toward whichever files happen to sort first.
            let take = min(needed, group.count)
            let stride = max(1, group.count / take)
            for index in Swift.stride(from: 0, to: group.count, by: stride).prefix(take) {
                selected.append(group[index])
            }
        }

        guard !selected.isEmpty else { return [] }

        Console.info("Re-digesting \(selected.count) cached file(s) with the cache bypassed, to time digestion.")
        let progress = Console.Progress(total: selected.count, label: "Timing digestion")

        var results: [DigestMeasurement] = []
        for (index, file) in selected.enumerated() {
            do {
                let digester = try DigesterFactory.digester(for: file.type)
                let (chunks, duration) = try await timed {
                    try await digester.digest(file: file.url, contextSize: options.contextSize)
                }
                results.append(
                    DigestMeasurement(
                        sourceKind: file.url.pathExtension.lowercased(),
                        sourceBytes: file.byteSize,
                        chunkCount: chunks.count,
                        milliseconds: duration.milliseconds,
                        servedFromCache: false
                    )
                )
            } catch {
                // A file that fails here was already reported as skipped by the main pass.
            }
            progress.advance(index + 1)
        }
        progress.finish()

        return results
    }

    /// Digests a file, reading from and writing to the on-disk chunk cache when enabled.
    ///
    /// - Returns: The chunks, how long digestion took in milliseconds, and whether the cache served it.
    ///            A cache hit reports the time the cache read took, and is excluded from the digestion
    ///            throughput tables.
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func digest(file: SourceFile) async throws -> (chunks: [EmbeddableContent], milliseconds: Double, cached: Bool) {
        let cacheURL = cacheLocation(for: file)

        if options.useCache, let data = try? Data(contentsOf: cacheURL) {
            let (chunks, duration) = try await timed {
                try PropertyListDecoder().decode([EmbeddableContent].self, from: data)
            }
            return (chunks, duration.milliseconds, true)
        }

        let digester = try DigesterFactory.digester(for: file.type)
        let (chunks, duration) = try await timed {
            try await digester.digest(file: file.url, contextSize: options.contextSize)
        }

        if options.useCache, let encoded = try? PropertyListEncoder().encode(chunks) {
            try? encoded.write(to: cacheURL)
        }

        return (chunks, duration.milliseconds, false)
    }

    /// The cache file for a source file, keyed by path, size, modification date and chunk size so that
    /// editing a file or changing `--context-size` invalidates it.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func cacheLocation(for file: SourceFile) -> URL {
        let identity = [
            file.url.path(percentEncoded: false),
            String(file.byteSize),
            String(file.modificationDate.timeIntervalSince1970),
            String(options.contextSize)
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return options.cacheDirectory.appending(path: "\(name).plist")
    }
}

// MARK: - Titles, descriptions and chunk numbering

extension CorpusBuilder {
    /// A title that is unique across the corpus, because `IrisDocument.title` carries a UNIQUE constraint.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func uniqueTitle(for url: URL, index: Int) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return "\(parent)/\(url.lastPathComponent)#\(index)"
    }

    /// A short description standing in for what the app would store, drawn from the opening text.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func description(for url: URL, chunks: [EmbeddableContent]) -> String {
        let opening = chunks.first?.textContent?.prefix(240) ?? ""
        return "\(url.deletingPathExtension().lastPathComponent). \(opening)"
    }

    /// Rewrites sequence indices and document length so chunk locations stay internally consistent
    /// after filtering or recombination.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func renumber(_ chunks: [EmbeddableContent]) -> [EmbeddableContent] {
        chunks.enumerated().map { offset, chunk in
            switch chunk {
            case .text(let content, var location):
                location.sequenceIndex = offset
                location.documentLength = chunks.count
                return .text(content: content, location: location)
            case .image(let content, let caption, var location):
                location.sequenceIndex = offset
                location.documentLength = chunks.count
                return .image(content: content, caption: caption, location: location)
            }
        }
    }
}

// MARK: - Synthetic scaling

extension CorpusBuilder {
    /// Builds additional documents by drawing chunks from the pool of real chunks.
    ///
    /// The corpus on disk tops out in the hundreds of documents, while the database is meant to hold a
    /// researcher's whole library. Rather than generating lorem ipsum, which would give SQLite's FTS5
    /// tokenizer an unrealistically small vocabulary and unrealistically short postings lists, each
    /// synthetic document is a resampling of genuine academic prose. Chunk length distribution, token
    /// distribution and per-document chunk counts therefore all match the real material.
    ///
    /// The known distortion is repetition: with a finite pool, chunks recur across synthetic documents,
    /// so identical embeddings collide in the FAISS index and BM25 sees inflated document frequencies.
    /// That shifts which results come back, not what the retrieval costs, which is what is being timed.
    ///
    /// - Parameters:
    ///   - count: How many documents to fabricate.
    ///   - sources: The real documents to draw chunks and chunk counts from.
    ///   - generator: The seeded generator, so a rerun produces the identical corpus.
    /// - Authored by: Claude Opus 5 (Anthropic)
    private func synthesize(
        count: Int,
        from sources: [PreparedDocument],
        generator: inout SeededGenerator
    ) -> [PreparedDocument] {
        let chunkPool: [EmbeddableContent] = sources.flatMap(\.chunks)
        let chunkCountDistribution = sources.map(\.chunkCount)
        guard !chunkPool.isEmpty, !chunkCountDistribution.isEmpty else { return [] }

        var synthetic: [PreparedDocument] = []
        synthetic.reserveCapacity(count)

        for index in 0..<count {
            // Sample a chunk count from the real distribution so document sizes stay realistic.
            let chunkCount = max(1, chunkCountDistribution.randomElement(using: &generator) ?? 1)

            // Draw a contiguous run from the pool so a synthetic document reads as continuous prose
            // rather than unrelated fragments, then wrap around at the end of the pool.
            let start = Int.random(in: 0..<chunkPool.count, using: &generator)
            var picked: [EmbeddableContent] = []
            picked.reserveCapacity(chunkCount)
            for offset in 0..<min(chunkCount, chunkPool.count) {
                picked.append(chunkPool[(start + offset) % chunkPool.count])
            }

            let renumbered = renumber(picked)
            let title = "synthetic/document-\(index)"

            synthetic.append(
                PreparedDocument(
                    uuid: UUID(),
                    title: title,
                    description: "Synthetic benchmark document \(index). \(renumbered.first?.textContent?.prefix(200) ?? "")",
                    chunks: renumbered,
                    origin: .synthetic,
                    sourceKind: "synthetic",
                    sourceBytes: 0,
                    textCharacters: renumbered.reduce(0) { $0 + ($1.textContent?.count ?? 0) }
                )
            )
        }

        return synthetic
    }
}
