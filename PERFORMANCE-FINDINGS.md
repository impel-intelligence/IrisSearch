# IrisSearch — bugs and scaling findings

Compiled 2026-08-11 while building the `IrisBenchmark` executable. Every item below was found either
by reading the code or by running the benchmark against a real corpus.

**Nothing in this document has been fixed**, with one exception that is called out explicitly
(finding 3, which had to be fixed before the benchmark could read Markdown at all).

## How these were found

| | |
| --- | --- |
| Hardware | Apple M1 Max, 10 cores, 64 GiB RAM, macOS 26.6.1 |
| Build | release (`swift build -c release`) |
| Corpus | 650 real documents / 86,142 chunks from ArXiv, MIT OCW, WikiBooks and RIT course material; padded to 2,000 documents / 285,080 chunks with documents recombined from real chunks |
| Embedders | `bge_small_en_v1.5` via `CoreMLEmbedder` (d=384, the shipped model), and a zero-cost hash embedder (d=512) used to isolate database cost from model cost |
| Artifacts | `BenchmarkResults/hash/`, `BenchmarkResults/bge/` |

## Confidence labels

- **Verified** — I read the code and/or reproduced the behaviour myself.
- **Measured** — backed by numbers in `BenchmarkResults/`.
- **Unverified** — reported by a research subagent and *not* independently checked. Treat as a lead.

---

# Correctness and relevance

## 1. `search(within:)` throws away its own ranking — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:473-476`

```swift
// Any pieces that were actually surfaced by the piece searching
let surfacedPieceIDs = Set(semanticTextPieces.map(\.id) + syntacticTextDocumentPieces.map { Int($0.id) })

// Take the top n ranked pieces.
let limitedPieceIDs = Array(surfacedPieceIDs.prefix(nItems))
```

`surfacedPieceIDs` is a `Set`. `Set.prefix(n)` returns `n` elements in the set's *hash order*, which is
arbitrary and unrelated to relevance. The comment says "Take the top n ranked pieces", but
`rankedPieceIDs` — computed immediately above at line 462 — is never consulted for this selection.

The pieces that survive are then sorted by rank at lines 482-491, which makes the output *look*
correctly ordered. It is a correctly ordered ranking of an arbitrary subset. The single most relevant
piece in a document is dropped whenever it falls outside an arbitrary `nItems` slice of the candidate
set.

There is a second, compounding defect on line 482: `orderedByRank` is sized `limitedPieceIDs.count`,
but ranks are positions in the full `rankedPieceIDs` list, so line 486's `rank < orderedByRank.count`
guard silently discards any surviving piece whose rank exceeds the slice size. A call can therefore
return fewer results than it selected.

Note the corpus-wide `search(query:)` does **not** have this bug — line 644 uses
`rankedDocumentIDs.prefix(nItems)`, which is a properly ordered `Array`.

**Impact:** In-document search returns near-random relevance. This is a quality bug, not a speed bug,
and no benchmark would have caught it.

**Expected fix:** Select from the ranked array, then intersect with the surfaced set:

```swift
let surfacedPieceIDs = Set(semanticTextPieces.map(\.id) + syntacticTextDocumentPieces.map { Int($0.id) })
let limitedPieceIDs = rankedPieceIDs.filter { surfacedPieceIDs.contains($0) }.prefix(nItems)
```

Then size `orderedByRank` by `limitedPieceIDs.count` and re-index ranks densely (`0..<count`) rather
than reusing global rank positions. Add a test asserting that the top-ranked piece is always present
in the result for `nItems >= 1`.

---

## 2. The BGE query prefix is never applied — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:431` and `:533`

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

## 3. Markdown files could not be digested — Verified, and FIXED

**Where:** `Sources/Digester/Implementations/MarkdownDigester.swift:20`

```swift
static let fileTypes: [UTType] = [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
```

`UTType(importedAs:conformingTo:)` only resolves to the real identifier when the running process
declares or imports that UTI in its `Info.plist`. In a process that does not — any command line tool,
and any test runner without the declaration — it silently returns a generated `com.unknown.md` type.
Reproduced directly:

```
declared: net.daringfireball.markdown  isDeclared=true
imported: com.unknown.md               isDeclared=true
equal: false
```

Consequence chain: `DigesterFactory` filters by conformance, and declared-Markdown does not conform
to `com.unknown.md`, so `MarkdownDigester` is excluded; `TXTDigester` wins instead; then
`TXTDigester.validateLocalURL` rejects the file because Markdown is not in its `fileTypes`. **All 276
Markdown files in the test corpus failed to digest.**

The existing tests do not catch this because `FactoryTests` passes `MarkdownDigester.fileTypes` as its
own argument, comparing the broken value against itself.

**Fix applied** (prefer the system-declared type, fall back to the import):

```swift
static let fileTypes: [UTType] = [
    UTType("net.daringfireball.markdown")
        ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
]
```

**Still worth doing:** a regression test that resolves the type from a real `.md` file path
(`UTType(filenameExtension:)`) rather than from `fileTypes`, so this cannot silently regress.

---

## 4. `validateLocalURL` and `DigesterFactory` disagree on type matching — Verified

**Where:** `Sources/Digester/FileDigester.swift` (`validateLocalURL`) vs
`Sources/Digester/DigesterFactory.swift` (`digester(for:)`)

The factory selects a digester by **conformance** (`isValidType` → `type.conforms(to:)`), but each
digester then validates the file by **exact equality** (`fileTypes.contains(fileType)`). A type can
therefore pass selection and fail validation, which is exactly the failure mode in finding 3.

**Impact:** Any subtype of a supported type is routed to a digester that then rejects it. The
practical breakage is fixed by finding 3, but the inconsistency remains and will produce the same
class of bug for the next subtype anyone adds.

**Expected fix:** Make `validateLocalURL` use the same conformance check the factory uses
(`Self.isValidType(fileType)`). This is strictly more permissive; audit that no digester relies on
the stricter behaviour for safety.

---

## 5. The two search paths use different full-text semantics — Verified

**Where:** `IrisDB.swift:443` uses `FTS5Pattern(matchingAnyTokenIn:)` (OR), `IrisDB.swift:546` and
`:564` use `FTS5Pattern(matchingAllTokensIn:)` (AND).

Searching inside a document is disjunctive; searching the corpus is conjunctive. The same query text
therefore behaves differently depending on scope — corpus-wide search of a full sentence typically
matches nothing in FTS5 and is carried entirely by the vector index.

**Impact:** Surprising and undocumented behavioural difference. Benchmark data shows the cost
difference clearly: at 2,000 documents, sentence queries ran 154.46 ms p50 against 68.69 ms for a rare
term.

**Expected fix:** Decide deliberately and document it. If conjunctive is right, long natural-language
queries need a fallback (drop to OR when AND yields zero rows), or recall will keep depending on the
vector half alone.

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

Measured, at 384 dimensions, ingesting 2,000 documents:

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

`FlatIndex` is brute force. Measured with the shipped BGE model:

| documents | chunks | search p50 | p90 | p99 |
| --- | --- | --- | --- | --- |
| 250 | 31,713 | 16.20 ms | 18.43 | 24.44 |
| 500 | 76,357 | 25.87 ms | 37.58 | 48.32 |
| 1000 | 130,596 | 36.89 ms | 56.42 | 71.08 |
| 2000 | 285,080 | 76.97 ms | 125.39 | 153.25 |

9× the vectors for 4.8× the latency — linear, as the structure predicts. Query embedding is flat at
~5.4 ms, so it falls from 27% of search latency at 100 documents to 7.6% at 2,000. **The model is not
the bottleneck; the index is.**

**Impact:** Linear extrapolation puts search in the hundreds of milliseconds to seconds at 10k-50k
documents. Memory is the harder wall: full-precision storage at 50k documents is ~11 GB resident.

**Expected fix:** Move to an approximate index above a vector-count threshold — `IVF{nlist},SQ8` is
the leading candidate because IVF supports incremental add *and* delete, which this app needs, and SQ8
cuts memory ~4×. Below ~150k vectors, stay flat; above it, train on a sample and rebuild in the
background. **This changes search results**, so it requires a recall evaluation — capture flat-index
results as ground truth *now*, while exhaustive search is still cheap.

---

## 9. The schema has no secondary indexes — Verified and Measured

**Where:** `Sources/IrisSearch/IrisDB.swift:67-119`. `grep` for `create(index`/`indexed()` returns
nothing. The `table.foreignKey(["parentID"], references: "documents", onDelete: .cascade)` on line 92
does **not** create an index.

Every `readDocument`, `readPiece` and `search(within:)` issues
`SELECT … FROM document_pieces WHERE parentID = ?` against an unindexed column.

Measured `search(within:)` p50:

| documents | in-document search p50 |
| --- | --- |
| 100 | 20.40 ms |
| 500 | 83.15 ms |
| 1000 | 127.83 ms |
| 2000 | **330.95 ms** |

16× growth for a 20× corpus. In-document search should be **flat** — it searches one document. The
per-document FAISS index is far too small to explain this; the table scan is.

**Impact:** The worst scaling behaviour measured anywhere in the system, on the cheapest possible fix.

**Expected fix:** `CREATE INDEX idx_document_pieces_parentID ON document_pieces(parentID)` as a new
migration. Note the index **must be named** — `CREATE INDEX ON …` is invalid SQLite and will throw on
every database open. Prefer GRDB's `db.create(index:on:columns:)` over raw SQL.

---

## 10. Every corpus-wide search counts the whole piece table — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:520-522`

```swift
let maximumPieces = try await dbPool.read { db in
    return try DocumentPiece.fetchCount(db)
}
```

This runs on every search, solely to clamp `searchLimit` on line 527. It is an O(rows) b-tree scan
over a table that reached 227.80 MiB at 2,000 documents, and it grows linearly exactly like the FAISS
scan — meaning the measured search curve conflates two independent linear terms.

**Expected fix:** Maintain a cached count on the actor, invalidated on insert/update/delete. Or drop
the clamp: FAISS already returns fewer than `k` results when the index is small, and the `-1` labels
are filtered at `FaissIndex.swift:202`.

---

## 11. `search(within:)` hydrates the entire document to compute a count — Verified

**Where:** `Sources/IrisSearch/IrisDB.swift:422-426`

```swift
let document = try await readDocument(uuid: uuid)
...
let searchLimit = (nItems * 2).clamped(to: 0...document.pieces.count)
```

`readDocument(uuid:)` loads every piece including full `textContent` and every `dataContent` blob. For
the corpus's largest document (2,738 chunks) that is megabytes of hydration before the search begins,
mostly to obtain `pieces.count`. Compounded by finding 9's missing index.

**Expected fix:** `SELECT COUNT(*) … WHERE parentID = ?` for the clamp, and fetch the document row
without its pieces. The pieces that matter are fetched separately at line 478 anyway.

---

## 12. One FAISS index file per document — Verified and Measured

**Where:** `Sources/IrisSearch/FaissIndex.swift:16-27`, `:132-141`

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

First search against a freshly opened `IrisDB`, which deserializes the whole global index:

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

**Where:** `Sources/IrisSearch/FaissIndex.swift:167-170`

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
while its SQLite rows are already gone (deleted by the caller at `IrisDB.swift:379-381`).

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

Ordered by value per unit of risk. Items 1-4 do not change search results; items 5-6 do.

| # | Finding | Why first |
| --- | --- | --- |
| 1 | 9 — `parentID` index | One migration. Worst measured scaling in the system. |
| 2 | 2 — `embedQuery` | One line. Improves relevance app-wide. Needs a relevance check, no re-indexing. |
| 3 | 1 — `search(within:)` ranking | Small, self-contained, and currently returns near-random relevance. |
| 4 | 6 → 7 → 12 | Vectors in SQLite unlocks batched flush and deleting per-document indices. Removes the quadratic intake term. |
| 5 | 13 — mmap cold start | Depends on finding 19 being resolved. |
| 6 | 8 — approximate index | Largest win, largest risk. Needs a recall harness built first — capture flat-index ground truth *before* migrating. |

Findings 10, 11, 15, 16, 17, 18 are small and can ride along with whatever touches their file.
Finding 14 needs reproducing in isolation and is independent of everything else.
