<!-- Compiled by Claude Opus 5 (Anthropic); revised 2026-08-13 against 48c8d97. -->

# IrisSearch — bugs and scaling findings

**State of the code as of `48c8d97`.** Every item below is open against that commit. All line numbers
are relative to it. This document describes what the code does *now* — items that have been fixed are
deleted rather than archived, so the numbering is not contiguous. Numbers are stable identifiers:
a closed finding's number is never reused, so a note referring to "finding 8" keeps its meaning.

## Current baseline

`BenchmarkResults/piececount-after/` — the most recent full run, and the only one that reflects the
current search path. Everything quoted in this document comes from it unless stated otherwise.

| | |
| --- | --- |
| Hardware | Apple M1 Max, 10 cores, 64 GiB RAM, macOS 26.6.1 |
| Build | release (`swift build -c release`) |
| Corpus | 1,000 documents / 140,776 chunks — 652 real (ArXiv, MIT OCW, WikiBooks, RIT course material), 348 synthetic documents recombined from real chunks |
| Chunks per document | mean 140.8, median 7, max 8,591 |
| Embedder | hash embedder, d=512 (zero-cost, no semantics) |
| Checkpoints | 250 and 1,000 documents |

| documents | chunks | intake ms/doc | search p50 | p90 | p99 | in-doc p50 | cold ms | on disk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 250 | 28,782 | 25.1 | 9.93 | 81.12 | 98.00 | 20.29 | 383.5 | 138.09 MiB |
| 1000 | 140,776 | 73.0 | 30.08 | 495.63 | 587.67 | 65.64 | 1,861.7 | 698.36 MiB |

p50 by query shape:

| documents | rareTerm | commonTerm | phrase | question | sentence |
| --- | --- | --- | --- | --- | --- |
| 250 | 2.94 | 5.80 | 10.19 | 51.05 | 81.58 |
| 1000 | 8.50 | 16.08 | 30.63 | **324.30** | **505.39** |

Storage and mutation at 1,000 documents: SQLite 114.30 MiB, global FAISS index 276.03 MiB,
per-document indices 293.56 MiB across 1,001 files, process memory 633.52 MiB, 131.90 GiB of
cumulative index rewriting. `updateDocument` 236.9 ms mean, `deleteDocument` 89.7 ms mean.

**Read these caveats before quoting any number above.**

- **The hash embedder was used, not the shipped model.** Query embedding is therefore free (0.00 ms,
  0% of search) where `CoreMLEmbedder` costs single-digit milliseconds per query, and hashed vectors
  clear `semanticCutoff = 0.6` less often than real ones, so fewer candidates get hydrated. There is
  no current run against `bge_small_en_v1.5`. These numbers describe the storage and retrieval
  layers, not end-to-end search cost or quality.
- **Two checkpoints only.** The run's fitted exponents (`0.025119 × vectors^0.67` for intake,
  `0.007669 × vectors^0.70` for median search) are two-point slopes. Their reported `R² = 1.000` is
  degenerate — two points always fit a line exactly — and carries no information about the fit.
  Treat the exponents as a ratio between two measurements, and do not extrapolate an order of
  magnitude past 1,000 documents without more checkpoints.
- **35% of the corpus is synthetic.** Synthetic documents resample runs of real chunks, so chunk
  length and vocabulary match, but chunks recur across documents. That collides vectors in FAISS and
  inflates the document frequencies BM25 sees. It changes which results come back, not what
  retrieval costs.
- **PDF page images were excluded.** `PDFDigester` renders every page to JPEG; those pieces are
  stored but never embedded. Rerun with `--include-images` for the storage cost the app actually pays.
- **Cold search is a floor.** The OS file cache still held the index file. A genuine cold boot is
  slower.

## Confidence labels

- **Verified** — I read the code and/or reproduced the behaviour myself.
- **Measured** — backed by numbers in `BenchmarkResults/`.
- **Unverified** — reported by a research subagent and *not* independently checked. Treat as a lead.

---

# Correctness and relevance

## 3. `FactoryTests` cannot catch a markdown UTType regression — Verified

**Where:** `Tests/DigesterTests/FactoryTests.swift:37`

`testMarkdownDigesterDefaultTypes` parameterises on `MarkdownDigester.fileTypes` and then asserts
that the factory returns a `MarkdownDigester` for each — it compares the value against itself. The
underlying defect it is meant to guard (markdown files failing to digest because
`UTType(importedAs:)` resolves to `com.unknown.md` outside a process that declares the UTI) is fixed,
but nothing would catch it coming back.

**Expected fix:** Resolve the type from a real `.md` path via `UTType(filenameExtension:)` and assert
the factory returns a `MarkdownDigester` for *that*.

---

## 5. FTS5 is disjunctive everywhere, which buys recall at a large latency cost — Verified and Measured

**Where:** `Sources/IrisSearch/IrisDB.swift:479`, `:587`, `:605` — all three use
`FTS5Pattern(matchingAnyTokenIn:)`.

Both search paths OR the query's tokens. That is a deliberate choice and it is load-bearing for
recall: at 1,000 documents a request for 10 results returns a mean of 9.7. It is also the single
largest latency term in the system for natural-language queries — a sentence query costs 505 ms p50
at 1,000 documents, and overall p90 is 495.63 ms.

**Cause:** `.limit(searchLimit)` bounds rows *returned*, not rows *scanned*. FTS5 must BM25-score
every matching row to order them, and OR over a ~30-token sentence matches an enormous fraction of
the chunk table. Single-token queries are unaffected — `rareTerm` is 8.50 ms and `commonTerm` 16.08 ms
at the same checkpoint — so the cost is confined entirely to multi-token queries. It scales with
corpus size, so 2,000 documents is roughly a second for a sentence query.

**The conjunctive alternative, for reference.** `BenchmarkResults/fts-all/` measured
`matchingAllTokensIn:` on an earlier build of the same corpus and query suite. It is not directly
comparable — that build predates the current search path — but it brackets the trade:

| | overall p50 @1000 | p90 @1000 | sentence p50 @1000 | mean results at `nItems = 10` |
| --- | --- | --- | --- | --- |
| ALL (conjunctive) | 11.55 | 32.28 | 33.16 | 5.6 |
| ANY (current) | 30.08 | 495.63 | 505.39 | **9.7** |

AND is not a free win: reverting `IrisDB.swift` to conjunctive matching and running `sonnetSearch`
(`Tests/IrisSearchTests/SearchTests.swift`) fails with `(documents.count → 0) == (kItems → 10)` — a
total recall failure over 154 sonnets. Disjunctive matching passes it.

**Expected fix:** AND first, fall back to OR when the conjunctive query yields too few rows. That
keeps AND's latency in the common case and OR's recall when it matters. Capping query tokens by IDF —
keeping the most selective N terms — is a complement or an alternative. Whichever is chosen, measure
it on the current build; the A/B is cheap (two checkpoints, hash embedder).

Note that this makes *widening* the candidate pool actively harmful on exactly the queries that are
already slow.

---

# Durability

## 6. Embeddings exist in exactly one place, and it is written non-atomically — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:123-127` and `Sources/IrisSearch/FaissIndex.swift:178`

The `Remove Embeddings Column` migration dropped embeddings from SQLite:

```swift
migrator.registerMigration("Remove Embeddings Column") { db in
    try db.alter(table: DocumentPiece.databaseTableName) { table in
        table.drop(column: "embeddings")
    }
}
```

`DocumentPiece.init(row:)` confirms it — `embeddings = []` when loading from the database. So the
FAISS index file is the **only** copy of every embedding in the system. And `FaissIndex.add(pieces:to:)`
writes it in place:

```swift
try index.saveToFile(indexURL.path(percentEncoded: false))
```

There is no temp-file-plus-rename. A crash, a full disk, or a kill during that write leaves a
truncated index and no way to recover the vectors short of re-embedding the entire corpus.

**Impact:** Two problems. Data loss risk on any interrupted write — and this write happens on *every
single insert*, so the exposure window is constant during import. Second, it makes any future
index-format change (finding 8) require full re-embedding, because there is no source to rebuild from.

**Expected fix:** Persist vectors alongside the pieces, e.g. a
`piece_vectors(pieceID INTEGER PRIMARY KEY, vector BLOB)` table written in the same transaction as
the pieces in `performCreateDocument`. Float16 halves the cost at negligible retrieval impact.
SQLite then becomes the source of truth and the index becomes a rebuildable cache. Separately, write
the index to `.tmp` and `rename()` for atomicity.

This is a prerequisite for findings 7 and 8.

---

# Performance and scaling

## 7. Every insert rewrites the entire global index — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:126-130` → `:143-179`

`addDocument` calls `addDocumentToGlobalIndex` for every document, which calls
`add(pieces:to:.global)`, which ends in `saveToFile`. `updateDocument` and `deleteDocument` do the same.

| documents | global index | cumulative bytes rewritten |
| --- | --- | --- |
| 250 | 56.43 MiB | 6.98 GiB |
| 1000 | 276.03 MiB | **131.90 GiB** |

4× the documents for 19× the cumulative writes — quadratic, as the structure predicts. Mutation
inherits it: `updateDocument` costs 236.9 ms mean (p99 1,422 ms) and `deleteDocument` 89.7 ms mean at
1,000 documents. It is also the mechanism behind the intake curve: 25.1 → 73.0 ms per document.

Projecting to 50,000 documents at this corpus's 140.8 chunks/document gives ~7.0M vectors and a
~13.8 GiB global index at d=512 (~10.4 GiB at the shipped model's d=384). Cumulative writes reach
roughly **340 TiB** — tens of hours of pure index writing, before any other cost.

**Impact:** This is the dominant intake cost for the database layer, and it is write amplification
against the user's SSD. It is not inherent to anything — it is a flush policy.

**Expected fix:** Dirty-flag with a debounced flush (flush on idle, on a pending-vector threshold, on
app background/terminate, and on an explicit new `IrisDB.flush()`), with durability provided by
finding 6's SQLite vectors plus a generation marker for crash replay. Add a
`flushPolicy: .immediate | .debounced(_)` initializer option so tests can pin the current behaviour.
Consider a `createDocuments(_:)` batch API for imports.

---

## 8. Vector search is exhaustive — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:106`

```swift
let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .innerProduct)
```

`FlatIndex` is brute force — every query scans every vector. Search p50 goes 9.93 → 30.08 ms for
4.9× the vectors, and the FAISS scan is one of the two terms in that (finding 5's FTS5 scan is the
other, and dominates on multi-token queries). Query embedding contributes 0.00 ms here only because
the hash embedder is free.

**Impact:** Memory is the harder wall, not latency. Process memory is already 633.52 MiB at 1,000
documents. Full-precision storage at 50,000 documents is ~13.8 GiB resident at d=512, ~10.4 GiB at
d=384 — before the per-document indices in finding 12 are counted.

**Expected fix:** Move to an approximate index above a vector-count threshold — `IVF{nlist},SQ8` is
the leading candidate because IVF supports incremental add *and* delete, which this app needs, and
SQ8 cuts memory ~4×. Below ~150k vectors, stay flat; above it, train on a sample and rebuild in the
background. **This changes search results**, so it requires a recall evaluation — capture flat-index
results as ground truth *now*, while exhaustive search is still cheap.

---

## 12. One FAISS index file per document — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:16-27`, `:132-141`

| documents | per-document indices | global index | files |
| --- | --- | --- | --- |
| 250 | 57.87 MiB | 56.43 MiB | 251 |
| 1000 | 293.56 MiB | 276.03 MiB | 1,001 |

The per-document indices cost slightly *more* than the global index — they store the same vectors a
second time — and would mean 50,001 files at target scale. They also double the write cost per insert.

**Expected fix:** Delete them. Once vectors live in SQLite (finding 6), `search(within:)` can score
one document's vectors directly with Accelerate; the corpus median is 7 chunks and the maximum 8,591,
so even the worst case is low single-digit milliseconds, and it is *exact*. This also removes
`refreshIndex`, the `cachedDocumentIndices` cache (finding 15) and the fragile delete in finding 17.

---

## 13. Cold start is linear in corpus size — Measured

First search against a freshly opened `IrisDB`, which deserializes the whole global index:

| documents | global index | cold search |
| --- | --- | --- |
| 250 | 56.43 MiB | 383.5 ms |
| 1000 | 276.03 MiB | 1,861.7 ms |

~148 MiB/s of deserialization. Loading is already lazy, so deferring further only relocates the
stall. At the finding 7 projection of a ~13.8 GiB index, 50,000 documents is ~95 s of cold start.

**Note:** the OS file cache was warm during these measurements. A genuine cold boot is **slower**.

**Expected fix:** Memory-map the index on load. This depends on the SwiftFaiss issues in finding 19
and requires the read-mmap + owned-delta split, because a memory-mapped index cannot be mutated in
place.

---

## 20. `search(within:)` runs a corpus-wide FTS5 query and filters afterwards — Verified and Measured

**Where:** `Sources/IrisSearch/IrisDB.swift:485-491`

```swift
let documents = try SearchableDocumentPiece
    .matching(pattern)
    .select(Column("id"), Column("textContent"), Column("parentID"), Column.rank)
    .filter(Column("parentID") == document.id)
    .order(Column.rank)
    .limit(searchLimit)
    .fetchAll(db)
```

`.matching(pattern)` is unscoped: FTS5 matches and BM25-scores every row in the corpus, and the
`parentID` predicate discards all but one document's worth afterwards. In-document search therefore
pays the full corpus-wide full-text cost — including finding 5's OR blow-up — to search a single
document.

The semantic half does not have this problem: line 469 queries the per-document FAISS index
(`collection: uuid`), so it is genuinely scoped. The FTS5 query is the only corpus-scaling term left
in `search(within:)`.

**Measured:** in-document p50 is 20.29 ms at 250 documents against 65.64 ms at 1,000 — 3.2× for 4.9×
the vectors, on an operation that searches one document and should be flat. It is also *more*
expensive than corpus-wide search at both checkpoints (9.93 and 30.08 ms), which only makes sense if
it is doing the corpus-wide work plus extra.

Part of that growth is a benchmark artefact: `measureWithinDocumentSearch` samples a random document
per query (`Sources/IrisBenchmark/Benchmarks/SearchBenchmark.swift:143`), and the corpus averages
115 chunks per document at the 250 checkpoint against 141 at 1,000, so the documents being searched
are ~1.22× larger. That does not account for 3.2×.

**Expected fix:** Scope the FTS5 match itself rather than filtering its output — restrict the MATCH
to the document's piece rowids (e.g. a `rowid IN (SELECT id FROM document_pieces WHERE parentID = ?)`
subquery that SQLite can push into the FTS5 scan), or maintain a per-document full-text index.
Re-measure in-document p50 at 250 and 1,000 documents; if the curve flattens, this was the whole
story.

---

# Robustness

## 14. FAISS/OpenMP hard-crashes under concurrent intake — Verified (observed)

Observed at the end of a full benchmark run, during parallel intake at concurrency 8, after
concurrency 1, 2 and 4 had each completed cleanly:

```
OMP: Error #13: Assertion failure at kmp_alloc.cpp(2520).
```

The process aborted. This is inside the OpenMP runtime vendored with SwiftFaiss, reached from FAISS,
driven from Swift's cooperative thread pool.

**Impact:** A hard abort, not a Swift error — `IrisDB` cannot catch it, and the actor boundary does
not prevent it, because FAISS spawns its own OpenMP threads underneath. The app drives FAISS the
same way.  Any in-flight index write is lost, which given finding 6 means potential corpus loss.

**Expected fix:** Investigate pinning FAISS to a single OpenMP thread (`omp_set_num_threads(1)`) or
serializing all FAISS entry points behind one executor, then confirm the crash disappears. Reproduce
in isolation first — the benchmark is a usable harness (`--concurrency 8`). Worth reporting upstream
to the `impel-intelligence/SwiftFaiss` fork with the OpenMP build configuration.

---

## 15. `cachedDocumentIndices` grows without bound — Verified

**Where:** `Sources/IrisSearch/FaissIndex.swift:40`

```swift
var cachedDocumentIndices: [UUID: IDMap] = [:]
```

Entries are added by `getIndex(for:)` and removed only by `removeDocument`. Every document searched
in a session is retained for the life of the process, with no eviction.

**Impact:** Unbounded memory growth proportional to distinct documents touched.

**Expected fix:** Bound it with an LRU, or remove per-document indices entirely (finding 12).

---

## 16. `train()` is called on every add with a single document's vectors — Verified

**Where:** `Sources/IrisSearch/FaissIndex.swift:168-170`

```swift
if !index.isTrained {
    try index.train(embeddings)
}
```

A no-op today, because `FlatIndex.isTrained` is always true. It becomes actively harmful the moment
finding 8's index change lands: it would train IVF centroids on one document's chunks, permanently
degrading recall for the whole corpus.

**Expected fix:** Remove it. Training belongs in an explicit, sampled, corpus-level step.

---

## 17. `removeDocument` deletes a file without checking it exists — Verified

**Where:** `Sources/IrisSearch/FaissIndex.swift:59-66`

```swift
let indexURL = IndexLocation.document(uuid: documentID).filePath(in: indexLocation)
try FileManager.default.removeItem(at: indexURL)
```

Throws if the per-document index is missing, which aborts the delete *before*
`removeDocumentFromGlobalIndex` runs — leaving the document's vectors orphaned in the global index
while its SQLite rows are already gone (deleted by the caller at `IrisDB.swift:402-404`).

**Impact:** A partial delete that leaves the index inconsistent with the database. Reachable if a
prior create failed after the SQLite insert.

**Expected fix:** Guard on existence, or ignore a "no such file" error and continue to the global
removal. Better: remove from the global index first, so the durable half happens before the fragile
half.

---

## 18. Dead variable — Verified

`Sources/IrisSearch/FaissIndex.swift:127` binds `indexURL` in `addDocumentToGlobalIndex` and never
uses it. Cosmetic; the compiler warns.

---

# Leads I have not verified

## 19. SwiftFaiss fork defects — Unverified

Reported by a research subagent against the checkout at `.build/checkouts/SwiftFaiss` (rev
`e1ee2399`, v0.4.1). **I did not independently confirm any of these.** They are load-bearing for
findings 8 and 13, so confirm before planning work around them.

- `Sources/SwiftFaiss/IndexIO.swift:14` maps `.mmap` to `FAISS_IO_FLAG_MMAP` = 1, but in faiss 1.14.3
  the value 1 is `IO_FLAG_SKIP_STORAGE`. Passing `.mmap` would therefore *skip the storage* rather
  than memory-map it. The flag wanted for flat/HNSW is claimed to be `IO_FLAG_MMAP_IFC = 1 << 9`.
- `Sources/SwiftFaiss/IndexPointer.swift:5` — `init` is internal, so an `OpaquePointer` obtained by
  calling `SwiftFaissC` directly cannot be wrapped in a SwiftFaiss type. This would block working
  around the above from app code.
- `Sources/SwiftFaissC/include/bridge.h` omits `IndexHNSW_c.h`, so `SearchParametersHNSW` (and
  `efSearch`) are invisible to Swift even though the symbols ship in the binary.
- `AnyIndex.IVFPQ` (`AnyIndex.swift:47-49`) emits factory string `"PQ{m}x{nbit}"` — a flat PQ index
  with no IVF at all.
- `IndexHNSW` has no `remove_ids` override and inherits the base implementation, which throws. If
  true, HNSW is disqualified for this app without a tombstone-and-rebuild layer.

Also claimed and unverified: `index_factory` is fully exposed via
`AnyIndex(d:metricType:description:)`, so `IVF`/`HNSW` variants may be constructible today without
changing the fork.

---

# Suggested order

Ordered by value per unit of risk. Findings 5 and 8 change what search returns and need a relevance
or recall check; the rest are latency and durability work that leaves results identical.

| # | Finding | Why here |
| --- | --- | --- |
| 1 | 20 — scope the in-document FTS5 match | Small, self-contained, and the only remaining explanation for in-document search scaling with corpus size. Also the cheapest way to blunt finding 5 on the in-document path. |
| 2 | 5 — AND-first with OR fallback | 505 ms p50 for a sentence query at 1,000 documents is user-visible today and grows with the corpus. The recall requirement is real, so this needs the fallback, not a revert. |
| 3 | 6 → 7 → 12 | Vectors in SQLite unlocks batched flush and deleting per-document indices. Removes the quadratic intake term and halves index storage. |
| 4 | 13 — mmap cold start | Depends on finding 19 being resolved. |
| 5 | 8 — approximate index | Largest win, largest risk. Needs a recall harness built first — capture flat-index ground truth *before* migrating. |

Findings 3, 15, 16, 17, 18 are small and can ride along with whatever touches their file. Finding 14
needs reproducing in isolation and is independent of everything else.

**Before any of this, get a run with the shipped model.** Every current number uses the hash
embedder, so nothing here says anything about query-embedding cost or retrieval quality, and the
semantic candidate volume is understated.
