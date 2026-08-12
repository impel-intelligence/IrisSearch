# IrisSearch — bugs and scaling findings

Compiled 2026-08-11 while building the `IrisBenchmark` executable; revised 2026-08-12 after the first
round of fixes landed. Every item below was found either by reading the code or by running the
benchmark against a real corpus.

Findings keep their original numbers after they are closed, so that commit messages and notes
referring to "finding 9" stay meaningful. **Numbering is therefore not contiguous** — closed findings
are summarised in the table below and their detail has been deleted from the body.

All line numbers are relative to `7899d23`. They were re-derived at the 2026-08-12 revision; the ones
in the original compilation were taken before the fixes shifted `IrisDB.swift` and were wrong.

## Closed

| # | Finding | Fixed in | Residual |
| --- | --- | --- | --- |
| 1 | `search(within:)` selected `nItems` from a `Set`, discarding its own ranking | `663bf21` | None. `limitedPieceIDs` now comes from `rankedPieceIDs.prefix(nItems)`, which also resolves the `orderedByRank` sizing defect: ranks are `0..<nItems` by construction, so the `rank < orderedByRank.count` guard can no longer silently drop a result. No test asserts it. |
| 3 | Markdown files could not be digested — `UTType(importedAs:)` resolved to `com.unknown.md` outside a process that declares the UTI | `776b2a7` | Open: `FactoryTests` still parameterises on `MarkdownDigester.fileTypes` itself (`Tests/DigesterTests/FactoryTests.swift:37`), so it compares the value against itself and cannot catch a regression. A test should resolve the type from a real `.md` path via `UTType(filenameExtension:)`. |
| 4 | `validateLocalURL` matched types by equality while `DigesterFactory` matched by conformance | `663bf21` | None. `FileDigester.swift:89` now calls `isValidType(fileType)`. |
| 9 | No index on `document_pieces(parentID)` | `663bf21` | None. Migration `Add Document Piece Parent ID Index` at `IrisDB.swift:119-121`. Measured effect below. |

Finding 5 (the two search paths used different FTS5 semantics) was **changed, not closed** — the
change fixed the divergence and bought recall at a real latency cost. It is still open, and is now
the record of that trade.

### What the `parentID` index actually bought

Hash embedder both sides, so this isolates the database. Pre-fix is `BenchmarkResults/hash/`
(`0509d05`), post-fix is `BenchmarkResults/fts-all/` (`663bf21`, identical FTS5 semantics, index
present). Chunk counts differ slightly between the two runs because the padding differs; treat these
as ratios, not exact deltas.

| docs | in-document p50 pre | post | corpus-wide p50 pre | post |
| --- | --- | --- | --- | --- |
| 250 | 33.84 ms | 18.55 ms | 11.67 ms | 3.57 ms |
| 1000 | 147.67 ms | 52.78 ms | 36.36 ms | 11.55 ms |

Roughly 2.8× on in-document search and 3.1× on corpus-wide search at 1,000 documents. Corpus-wide
search benefits because it hydrates each result document's pieces through the `parentID` association
at `IrisDB.swift:688-691`.

**In-document search is still not flat.** 18.55 → 52.78 ms is 2.8× growth for 4× the corpus, with p90
at 786.90 ms. It searches one document; it should not care how many others exist. Roughly 1.22× of
that is the benchmark sampling larger documents at the larger checkpoint (see finding 11); the rest is
real. Finding 11 — hydrating the whole document to compute a count — is the remaining suspect and is
the best-supported open performance item after finding 7.

## How these were found

| | |
| --- | --- |
| Hardware | Apple M1 Max, 10 cores, 64 GiB RAM, macOS 26.6.1 |
| Build | release (`swift build -c release`) |
| Corpus | 650 real documents / 86,142 chunks from ArXiv, MIT OCW, WikiBooks and RIT course material; padded to 2,000 documents / 285,080 chunks with documents recombined from real chunks |
| Embedders | `bge_small_en_v1.5` via `CoreMLEmbedder` (d=384, the shipped model), and a zero-cost hash embedder (d=512) used to isolate database cost from model cost |
| Artifacts | `BenchmarkResults/hash/`, `BenchmarkResults/bge/`, `BenchmarkResults/fts-all/`, `BenchmarkResults/fts-any/` |

**Measurement vintage matters.** `BenchmarkResults/hash/` and `BenchmarkResults/bge/` were both
measured at `0509d05`, before any fix. Every table sourced from them is labelled **pre-fix** and is
kept as the evidence that motivated the fix — do not quote it as current. `fts-all/` and `fts-any/`
were measured at `663bf21` and `7899d23` respectively and are labelled **post-fix**; both used the
hash embedder, so they say nothing about model cost or retrieval quality.

## Confidence labels

- **Verified** — I read the code and/or reproduced the behaviour myself.
- **Measured** — backed by numbers in `BenchmarkResults/`.
- **Unverified** — reported by a research subagent and *not* independently checked. Treat as a lead.

---

# Correctness and relevance

## 2. The BGE query prefix is never applied — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:435` and `:534`

Both search paths embed the query with `embed(content:)`:

```swift
let textEmbedding = try await textEmbedder.embed(content: unicodeNormalizedQuery).map({Float($0)})
```

But `EmbeddingProvider` declares a separate `embedQuery(content:)`
(`Sources/IrisCommon/EmbeddingProvider.swift:13`), and `CoreMLEmbedder` implements it specifically to
apply the model's search prefix (`Sources/Embedder/CoreML/CoreMLEmbedder.swift:117-118`):

```swift
public func embedQuery(content: String) async throws -> [Double] {
    let newContent = (configuration.searchPrefix ?? "") + content
```

The shipped model's `config.json` sets
`"searchPrefix": "Represent this sentence for searching relevant passages:"`. `grep` confirms
`embedQuery` appears nowhere in `IrisDB.swift`.

**Impact:** BGE is an asymmetric retrieval model — queries and passages are meant to be embedded into
different spaces via the prefix. Every query is currently embedded as though it were a passage. This
degrades retrieval quality across the whole app, silently, and costs nothing to fix.

**Expected fix:** Call `embedQuery(content:)` in both search methods. Because this changes embeddings,
it changes results: re-run any relevance evaluation afterwards. Passage embeddings in the index are
unaffected, so **no re-indexing is required**.

---

## 5. FTS5 is now disjunctive everywhere, which bought recall at a large latency cost — Verified and Measured

**Where:** `Sources/IrisSearch/IrisDB.swift:447`, `:541`, `:559` — all three now use
`FTS5Pattern(matchingAnyTokenIn:)`.

Originally the two search paths disagreed: in-document search was disjunctive (OR) and corpus-wide
search was conjunctive (AND), so the same query text behaved differently depending on scope, and a
corpus-wide search for a full sentence typically matched nothing in FTS5 and was carried entirely by
the vector index. `7899d23` resolved the divergence by making everything OR.

**That resolved the inconsistency and did not settle the underlying question.** The A/B below is the
evidence, and it cuts both ways.

`BenchmarkResults/fts-all/` is `663bf21` (corpus-wide AND) against `BenchmarkResults/fts-any/` at
`7899d23` (OR). Hash embedder, identical corpus and query suite, `nItems = 10`, two checkpoints each.

| docs | variant | overall p50 | p90 | p99 | mean results returned |
| --- | --- | --- | --- | --- | --- |
| 250 | ALL (AND) | 3.57 | 5.74 | 9.95 | 3.14 |
| 250 | ANY (OR) | 9.09 | 65.11 | 79.70 | **8.10** |
| 1000 | ALL (AND) | 11.55 | 32.28 | 41.87 | 5.55 |
| 1000 | ANY (OR) | 25.86 | 392.73 | 472.98 | **9.69** |

p50 by query category:

| category | ALL @250 | ANY @250 | ALL @1000 | ANY @1000 | factor @1000 |
| --- | --- | --- | --- | --- | --- |
| rareTerm | 2.95 | 2.96 | 9.03 | 8.70 | 0.96× |
| commonTerm | 5.14 | 5.36 | 17.18 | 15.77 | 0.92× |
| phrase | 3.54 | 9.75 | 11.31 | 27.81 | 2.5× |
| question | 3.14 | 43.36 | 8.15 | **247.06** | 30× |
| sentence | 3.93 | 65.96 | 33.16 | **403.34** | 12× |

The recall win is real: mean results returned went 5.55 → 9.69 of a requested 10 at 1,000 documents.
Reproduced directly on `sonnetSearch` (`Tests/IrisSearchTests/SearchTests.swift`) by reverting
`IrisDB.swift` to `663bf21` and running it — under ALL it fails with `(documents.count → 0) == (kItems
→ 10)`, a total recall failure over 154 sonnets; under ANY it passes. Single-token queries
(`rareTerm`, `commonTerm`) are unaffected or marginally faster, so the regression is confined to
multi-token queries.

The cost is equally real: multi-token natural-language queries got 12-30× slower, and 403 ms p50 for
a sentence query at 1,000 documents is already user-visible. It scales with corpus size, so 2,000
documents is roughly 800 ms.

**Cause:** `.limit(searchLimit)` bounds rows *returned*, not rows *scanned*. FTS5 must BM25-score
every matching row to order them, and OR over a ~30-token sentence matches an enormous fraction of the
chunk table. This also means widening the candidate pool (finding 10) is now actively harmful on
exactly the queries that are already slow.

**Expected fix:** AND first, fall back to OR when the conjunctive query yields too few rows. That
keeps AND's latency in the common case and OR's recall when it matters. Cap query tokens by IDF —
keeping the most selective N terms — as a complement or an alternative. Whichever is chosen, re-run
this A/B; it is cheap (two checkpoints, hash embedder) and it is the only thing standing between an
opinion and a decision.

**Note on prior write-ups:** an earlier summary of this A/B compared ALL at 250 documents against ANY
at 1,000 and reported 78-103× regressions. That comparison was invalid. The correct same-checkpoint
factors are in the table above.

---

# Durability

## 6. Embeddings exist in exactly one place, and it is written non-atomically — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:113-117` and `Sources/IrisSearch/FaissIndex.swift:178`

The `Remove Embeddings Column` migration dropped embeddings from SQLite:

```swift
migrator.registerMigration("Remove Embeddings Column") { db in
    try db.alter(table: DocumentPiece.databaseTableName) { table in
        table.drop(column: "embeddings")
    }
}
```

`DocumentPiece.init(row:)` confirms it — `embeddings = []` when loading from the database. So the
FAISS index file is now the **only** copy of every embedding in the system. And
`FaissIndex.add(pieces:to:)` writes it in place:

```swift
try index.saveToFile(indexURL.path(percentEncoded: false))
```

There is no temp-file-plus-rename. A crash, a full disk, or a kill during that write leaves a
truncated index and no way to recover the vectors short of re-embedding the entire corpus.

**Impact:** Two problems. Data loss risk on any interrupted write — and note this write happens on
*every single insert*, so the exposure window is constant during import. Second, it makes any future
index-format change (finding 8) require full re-embedding, because there is no source to rebuild from.

**Expected fix:** Persist vectors alongside the pieces, e.g. a
`piece_vectors(pieceID INTEGER PRIMARY KEY, vector BLOB)` table written in the same transaction as the
pieces in `performCreateDocument`. Float16 halves the cost at negligible retrieval impact. SQLite then
becomes the source of truth and the index becomes a rebuildable cache. Separately, write the index to
`.tmp` and `rename()` for atomicity.

This is a prerequisite for findings 7 and 8.

---

# Performance and scaling

## 7. Every insert rewrites the entire global index — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:126-130` → `:143-179`

`addDocument` calls `addDocumentToGlobalIndex` for every document, which calls `add(pieces:to:.global)`,
which ends in `saveToFile`. `updateDocument` and `deleteDocument` do the same.

Measured **pre-fix** (`0509d05`), at 384 dimensions, ingesting 2,000 documents. `FaissIndex.swift` has
not been touched since, so this is still current:

| documents | global index | cumulative bytes rewritten |
| --- | --- | --- |
| 100 | 19.20 MiB | 0.9 GiB |
| 500 | 149.72 MiB | 25.9 GiB |
| 1000 | 256.07 MiB | 97.1 GiB |
| 2000 | 419.77 MiB | **380.88 GiB** |

The cost is quadratic in document count. Projected to 50,000 documents (~7.1M chunks, ~11 GB index),
cumulative writes reach roughly **275 TB**, on the order of 32 hours of pure index writing. Mutation
inherits it: update measured 508.4 ms and delete 274.9 ms at 2,000 documents.

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

`FlatIndex` is brute force. Measured **pre-fix** (`0509d05`) with the shipped BGE model:

| documents | chunks | search p50 | p90 | p99 |
| --- | --- | --- | --- | --- |
| 250 | 31,713 | 16.20 ms | 18.43 | 24.44 |
| 500 | 76,357 | 25.87 ms | 37.58 | 48.32 |
| 1000 | 130,596 | 36.89 ms | 56.42 | 71.08 |
| 2000 | 285,080 | 76.97 ms | 125.39 | 153.25 |

9× the vectors for 4.8× the latency — linear, as the structure predicts. Query embedding is flat at
~5.4 ms, so it falls from 27% of search latency at 100 documents to 7.6% at 2,000. **The model is not
the bottleneck; the index is.**

**These absolute numbers are stale and overstate the cost.** They include the unindexed `parentID`
hydration that closed finding 9 removed; at 1,000 documents the same query suite dropped from 36.36 ms
to 11.55 ms on the hash embedder once the index existed. The *shape* is unchanged and is what matters
here — vector scan cost is linear in vector count either way, and removing a competing linear term
only makes the FAISS scan a larger share of what remains. Re-measure with BGE before quoting a
latency at scale.

**Impact:** Linear extrapolation puts search in the hundreds of milliseconds to seconds at 10k-50k
documents. Memory is the harder wall: full-precision storage at 50k documents is ~11 GB resident.

**Expected fix:** Move to an approximate index above a vector-count threshold — `IVF{nlist},SQ8` is
the leading candidate because IVF supports incremental add *and* delete, which this app needs, and SQ8
cuts memory ~4×. Below ~150k vectors, stay flat; above it, train on a sample and rebuild in the
background. **This changes search results**, so it requires a recall evaluation — capture flat-index
results as ground truth *now*, while exhaustive search is still cheap.

---

## 10. Every corpus-wide search counts the whole piece table — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:521-523`

```swift
let maximumPieces = try await dbPool.read { db in
    return try DocumentPiece.fetchCount(db)
}
```

This runs on every search, solely to clamp `searchLimit` on line 528. It is an O(rows) b-tree scan
over a table that reached 227.80 MiB at 2,000 documents, and it grows linearly exactly like the FAISS
scan — meaning the measured search curve conflates two independent linear terms.

**Expected fix:** Maintain a cached count on the actor, invalidated on insert/update/delete. Or drop
the clamp: FAISS already returns fewer than `k` results when the index is small, and the `-1` labels
are filtered at `FaissIndex.swift:202`.

Note that dropping the clamp is not purely an optimisation. The same count backs
`guard maximumPieces > 0 else { throw IrisDBError.noDocuments }` on line 525, so removing it changes
the empty-database path from a thrown error to an empty result — an API behaviour change. Caching the
count preserves the semantics; removing the clamp does not. Note also that finding 5 makes *widening*
the pool actively harmful under OR.

---

## 11. `search(within:)` hydrates the entire document to compute a count — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:426-430`

```swift
let document = try await readDocument(uuid: uuid)
...
let searchLimit = (nItems * 2).clamped(to: 0...document.pieces.count)
```

`readDocument(uuid:)` loads every piece including full `textContent` and every `dataContent` blob. For
the corpus's largest document (2,738 chunks) that is megabytes of hydration before the search begins,
mostly to obtain `pieces.count`.

**This is the leading remaining explanation for in-document search not being flat.** The `parentID`
index (closed finding 9) cut in-document p50 by ~2.8× but did not flatten the curve: 18.55 ms at 250
documents against 52.78 ms at 1,000, p90 786.90 ms. An index makes the row *lookup* cheap; it does
nothing about the volume of `textContent` and `dataContent` deserialized once the rows are found.

Part of that growth is an artefact — `measureWithinDocumentSearch` samples a random document per query
(`Sources/IrisBenchmark/Benchmarks/SearchBenchmark.swift:143`), and the padded corpus averages 115
chunks per document at the 250 checkpoint against 141 at 1,000, so the documents being searched are
~1.22× larger. That does not account for 2.8×. Something still scales with corpus size, and hydration
volume is the best candidate.

**Expected fix:** `SELECT COUNT(*) … WHERE parentID = ?` for the clamp, and fetch the document row
without its pieces. The pieces that matter are fetched separately at line 479 anyway. Measure
in-document p50/p90 at 250 and 1,000 documents before and after; if the curve flattens, this was the
whole story.

---

## 12. One FAISS index file per document — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:16-27`, `:132-141`

Measured pre-fix; `FaissIndex.swift` is unchanged, so these still hold:

| documents | per-document indices | files |
| --- | --- | --- |
| 500 | 166.45 MiB | 501 |
| 2000 | 437.99 MiB | 2,001 |

The per-document indices cost roughly as much as the global index — they store the same vectors a
second time — and would mean 50,001 files at target scale. They also double the write cost per insert.

**Expected fix:** Delete them. Once vectors live in SQLite (finding 6), `search(within:)` can score one
document's vectors directly with Accelerate; the corpus median is 7 chunks and the maximum 2,738, so
even the worst case is low single-digit milliseconds, and it is *exact*. This also removes
`refreshIndex`, the `cachedDocumentIndices` cache (finding 15) and the fragile delete in finding 17.

---

## 13. Cold start is linear in corpus size — Measured

First search against a freshly opened `IrisDB`, which deserializes the whole global index. Measured
pre-fix, but cold start is index deserialization and none of the fixes touch it:

| documents | cold search (BGE, d=384) | cold search (hash, d=512) |
| --- | --- | --- |
| 100 | 105.5 ms | 189.3 ms |
| 500 | 621.7 ms | 1,165.5 ms |
| 1000 | 1,107.7 ms | 1,880.2 ms |
| 2000 | 2,312.4 ms | 4,205.8 ms |

~133 MiB/s of deserialization. Loading is already lazy, so deferring further only relocates the stall.
Projected: ~16 s at 10k documents, ~80 s at 50k.

**Note:** the OS file cache was warm during these measurements. A genuine cold boot is **slower**.

**Expected fix:** Memory-map the index on load. This depends on the SwiftFaiss issues in finding 19
and requires the read-mmap + owned-delta split, because a memory-mapped index cannot be mutated in
place.

---

# Robustness

## 14. FAISS/OpenMP hard-crashes under concurrent intake — Verified (observed)

Observed at the end of a full BGE benchmark run, during parallel intake at concurrency 8, after
concurrency 1, 2 and 4 had each completed cleanly:

```
OMP: Error #13: Assertion failure at kmp_alloc.cpp(2520).
```

The process aborted. This is inside the OpenMP runtime vendored with SwiftFaiss, reached from FAISS,
driven from Swift's cooperative thread pool.

**Impact:** A hard abort, not a Swift error — `IrisDB` cannot catch it, and the actor boundary does not
prevent it, because FAISS spawns its own OpenMP threads underneath. The app drives FAISS the same way.
Any in-flight index write is lost, which given finding 6 means potential corpus loss.

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

Entries are added by `getIndex(for:)` and removed only by `removeDocument`. Every document searched in
a session is retained for the life of the process, with no eviction.

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
while its SQLite rows are already gone (deleted by the caller at `IrisDB.swift:383-385`).

**Impact:** A partial delete that leaves the index inconsistent with the database. Reachable if a
prior create failed after the SQLite insert.

**Expected fix:** Guard on existence, or ignore a "no such file" error and continue to the global
removal. Better: remove from the global index first, so the durable half happens before the fragile
half.

---

## 18. Dead variable — Verified

`Sources/IrisSearch/FaissIndex.swift:127` binds `indexURL` in `addDocumentToGlobalIndex` and never uses
it. Cosmetic; the compiler warns.

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

Ordered by value per unit of risk. Items 1, 2 and 6 change what search returns and need a relevance
or recall check; items 3, 4 and 5 are pure latency and durability work that leaves results identical.

| # | Finding | Why here |
| --- | --- | --- |
| 1 | 5 — AND-first with OR fallback | The current OR-everywhere behaviour is an accepted 12-30× latency regression on natural-language queries that nobody deliberately chose. Decide it, with the A/B rerun as the evidence. |
| 2 | 2 — `embedQuery` | One line. Improves relevance app-wide. Needs a relevance check, no re-indexing. |
| 3 | 11 — stop hydrating the document | Small and self-contained, and the best remaining explanation for in-document search scaling with corpus size after the `parentID` index. Finding 10 is the same shape and can ride along. |
| 4 | 6 → 7 → 12 | Vectors in SQLite unlocks batched flush and deleting per-document indices. Removes the quadratic intake term. |
| 5 | 13 — mmap cold start | Depends on finding 19 being resolved. |
| 6 | 8 — approximate index | Largest win, largest risk. Needs a recall harness built first — capture flat-index ground truth *before* migrating. |

Findings 15, 16, 17, 18 are small and can ride along with whatever touches their file. Finding 14
needs reproducing in isolation and is independent of everything else.
