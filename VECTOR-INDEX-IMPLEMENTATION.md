<!-- Authored by Claude Opus 5 (Anthropic) on 2026-08-13 -->

# Accelerate vector index — implementation pseudocode

Companion to the design decisions in the planning session. Pseudocode is Swift-flavoured but not compilable: it omits error plumbing and most bounds checks so the *ordering* stays visible, because the ordering is the part that is hard to get right and impossible to test after the fact.

Read §1 and §6 first. Everything else is mechanical; those two are where the correctness lives.

---

## 0. Type map

| Type | File | Responsibility |
| --- | --- | --- |
| `MappedRegion` | `Vector Index/Accelerate/MappedRegion.swift` | One refcounted read-only `mmap`. Never remapped in place. |
| `Durability` | `Vector Index/Accelerate/Durability.swift` | `barrier()`, `fullSync()`, `syncDirectory()` |
| `VectorFile` | `Vector Index/Accelerate/VectorFile.swift` | `[capacity × d]` float32 matrix |
| `SlotMapFile` | `Vector Index/Accelerate/SlotMapFile.swift` | slot → piece rowid; **owns the authoritative `slotCount`** |
| `DocumentLogFile` | `Vector Index/Accelerate/DocumentLogFile.swift` | append-only log of 64-byte document records |
| `Generation` | `Vector Index/Accelerate/Generation.swift` | the three files + their directory, opened together |
| `TiledScan` | `Vector Index/Accelerate/TiledScan.swift` | parallel tiled sgemv + top-k merge |
| `AccelerateIndex` | `Vector Index/Accelerate/AccelerateIndex.swift` | `VectorIndex` conformance; owns the current `Generation` |

---

## 1. The two rules everything else follows from

**Rule 1 — SQLite commits first; the index is a rebuildable cache.** `map.bin` stores `DocumentPiece` rowids, and SQLite assigns those during `didInsert`. You cannot write the map before SQLite has committed. `IrisDB.performCreateDocument` already does this in the right order (`dbPool.write` → `textIndex.addDocument`). Do not try to invert it. The consequence is that the index can lag SQLite after a crash, which §6 reconciles.

**Rule 2 — every index mutation is one synchronous, unyielded region.** `writeExecutor` is a `KeyedExecutor<UUID>`: it serialises writes *per document*, not globally, and searches bypass it entirely. Two `createDocument` calls for different documents genuinely interleave at every `await`. The only thing making that safe today is that `FaissIndex`'s methods are synchronous, so the actor is never yielded mid-mutation.

```
// FORBIDDEN — two concurrent creates both read slotCount = 1000 and write overlapping ranges.
func addDocument(_ doc) async throws {
    let start = slotCount
    await fsync()              // ← actor released here; the other create now reads the same start
    slotCount = start + n
}
```

Keep `addDocument` / `removeDocument` non-`async`. Get fsync amortisation from group commit (§7), never from suspension. Do not make the index an actor.

---

## 2. Durability primitives

**What we are buying, and what we are not.** Measured on an M1 Max / APFS SSD, 4 KiB write + sync, 200 iterations:

| primitive | mean | p50 | p99 |
| --- | --- | --- | --- |
| no sync | 0.000 ms | 0.000 | 0.000 |
| `fsync` | 0.033 ms | 0.030 | 0.152 |
| `F_BARRIERFSYNC` | 0.264 ms | 0.213 | 0.933 |
| `F_FULLFSYNC` | 4.628 ms | 4.436 | 7.468 |

Match the primitive to the failure mode:

- **Process death** (jetsam, force quit, `SIGKILL`, an uncaught crash) — the page cache is in the kernel and survives. Everything written with `pwrite` is visible to the next process. **No sync is needed at all.** This is overwhelmingly the most likely way the app dies.
- **Kernel panic** — page cache lost. Plain `fsync` covers it, for 0.033 ms.
- **Power loss** — the device write cache is lost too. Only `F_FULLFSYNC` covers it, for 4.6 ms.

The reason to sync at all is **ordering, not durability**. Without it, a flush can land the page holding `slotCount` while the pages holding the vector data are still dirty. You reopen to a live slot whose vectors were never written — zeros, which score exactly `0.0` and therefore outrank every legitimately negative cosine, surfacing near the top of results and resolving to a real piece rowid. Missing data is recoverable (§6 reconciles it into a re-embed); a live slot pointing at unwritten bytes is silently wrong forever.

```
enum Durability {
    // Hot path. Ordering + kernel-panic safety for 0.033 ms. Call on the payload files
    // BEFORE bumping slotCount; fsync(A) returning before fsync(B) is called orders A ahead of B.
    static func sync(_ fd: Int32) { fsync(fd) }

    // Power-loss durability. 4.6 ms — reserve it for compaction commit and clean shutdown,
    // where it happens once rather than once per batch.
    static func fullSync(_ fd: Int32) { fcntl(fd, F_FULLFSYNC) }

    // A rename is not durable until the containing directory is synced.
    static func syncDirectory(_ url: URL) {
        let dfd = open(url.path, O_RDONLY)
        defer { close(dfd) }
        fcntl(dfd, F_FULLFSYNC)
    }
}
```

**Plus a dirty bit, which is what turns "we hope the ordering held" into "we check."** Carry `cleanShutdown: Bool` in `map.bin`'s header: clear it on the first write after open, set it on close. If `open()` finds it clear, the process did not shut down cleanly — run the §6 reconcile unconditionally rather than trusting the tail of the log. This is the same trick filesystems use, and it costs nothing on the normal path.

Writes go through `pwrite(fd, buf, len, offset)`, **not** through the mapping. The mapping stays `PROT_READ`. This removes any need for `msync` and keeps the reader and writer paths independent.

---

## 3. MappedRegion

Growth publishes a *new* mapping. The old one lives until the last in-flight scan releases it, which is what will let the scan move off the actor later without a use-after-free.

```
final class MappedRegion {
    let base: UnsafeRawPointer
    let byteCount: Int

    init(fd: Int32, byteCount: Int) {
        base = mmap(nil, byteCount, PROT_READ, MAP_SHARED, fd, 0)
        // precondition base != MAP_FAILED
    }

    deinit { munmap(base, byteCount) }

    func floats(atSlot slot: Int, dimensions d: Int, count: Int) -> UnsafeBufferPointer<Float> {
        let offset = VectorFile.headerSize + slot * d * 4
        return UnsafeBufferPointer(start: base.advanced(by: offset).assumingMemoryBound(to: Float.self),
                                   count: count * d)
    }
}
```

Do **not** use `Data(contentsOf:options:.mappedIfSafe)`. It silently falls back to a full read when the volume is not deemed safe — a multi-GB resident allocation.

---

## 4. Headers and records

Keep the existing `StorageHeader` protocol and version-byte dispatch. Fix the three prototype bugs by construction: magic is bytes not a `String`, `byteSize` is a literal the layout is asserted against, and the version is read from offset 4 (after the magic), not offset 0.

```
// vectors.bin — header padded to a page so the matrix base is page-aligned.
VectorFile.headerSize = 4096
  0   magic       "IRIS"  (4 bytes, literal 0x49 0x52 0x49 0x53)
  4   version     u8 + 3 pad
  8   dimensions  u64
  16  capacity    u64          // NOT authoritative for count — slots only
  24  crc32       u32 + 4 pad  // over the header; whole-file CRC optional, see §14
  32… reserved, zeroed
  4096 vectors: capacity × d × 4, row-major.  Slot i at 4096 + i*d*4

// map.bin — random access at k offsets, never streamed, so one cache line of header is enough.
SlotMapFile.headerSize = 64
  0   magic       "IMAP"
  4   version     u8 + 3 pad
  8   slotCount   u64   ← THE AUTHORITATIVE COUNT AND THE COMMIT POINT
  16  deadCount   u64
  24  capacity    u64
  32  generation  u64
  40  crc32       u32 + 4 pad
  48… reserved
  64  entries: capacity × u64.  UInt64.max = tombstone.

// documents.bin — append-only log. 64-byte records: 4096/64 = 64 per page, so none straddle.
DocumentLogFile.headerSize = 64, recordSize = 64
  record:
    0   uuid        16 bytes
    16  documentID  u64      // SQLite rowid, equals document_pieces.parentID
    24  slotStart   u64
    32  slotCount   u32      // EMBEDDED slots — see §7, not document.pieces.count
    36  pieceCount  u32      // total pieces, for the slotCount <= pieceCount assertion
    40  seq         u64      // monotonic; makes "last record wins" well-defined
    48  flags       u32      // bit 0 = live
    52  crc32       u32      // over bytes 0..<52
    56  reserved    8 bytes
```

`UInt64.max` is safe as a tombstone: piece rowids are `INTEGER PRIMARY KEY AUTOINCREMENT`, so always positive and **never reused**. Preserve that property — it is what stops a leaked map entry from ever aliasing a future piece.

---

## 5. AccelerateIndex state

```
final class AccelerateIndex: VectorIndex {     // final class, NOT an actor, NOT Sendable
    private let root: URL                       // main.irisdb/vector-index
    private let dimensions: Int
    private var generation: Generation          // the three open files + their mapping
    private var lockFD: Int32                   // flock(LOCK_EX|LOCK_NB) on writer.lock

    // Group commit: in-memory count runs ahead of the durable one.
    private var pendingSlotCount: UInt64        // published to readers
    private var durableSlotCount: UInt64        // last value fsynced into map.bin's header
    private var appendsSinceFlush: Int

    // Folded from documents.bin at open, maintained on every mutation.
    private var ranges: [UUID: DocumentRange]
    private var nextSeq: UInt64

    var faultInjector: ((FaultPoint) throws -> Void)?   // §13
}
```

---

## 6. open()

Two passes that are easy to conflate and must not be. **Validate each record independently, then fold last-valid-wins.** Folding first and validating after loses documents: an interrupted update leaves an invalid record for X that shadows X's perfectly good previous range, and X disappears entirely.

```
func open(root, dimensions, dbPool) throws {
    lockFD = open(root/"writer.lock", O_CREAT|O_RDWR)
    guard flock(lockFD, LOCK_EX|LOCK_NB) == 0 else { throw .indexLockedByAnotherProcess }

    sweepOrphanGenerations(root)               // any index-<gen> not named by `current`

    guard let gen = readCurrentPointer(root) else { throw .needsReEmbed }   // fresh or migrating
    generation = try Generation.open(root/"index-\(gen)")

    // --- guards, all cheap, all catch silent-garbage classes ---
    guard generation.vectors.dimensions == dimensions else { throw .dimensionMismatch }   // model changed
    guard generation.map.headerCRCValid else { throw .corrupt }

    // Capacities can diverge if a crash landed between the two ftruncates. Take the min, re-grow.
    let capacity = min(generation.vectors.derivedCapacity, generation.map.derivedCapacity)
    try growBoth(to: capacity)

    durableSlotCount = generation.map.slotCount
    pendingSlotCount = durableSlotCount
    precondition(durableSlotCount <= capacity)

    // --- pass 1: validate each record on its own merits ---
    var valid: [Record] = []
    for record in generation.documents.records() {
        guard record.crcValid else { continue }                            // torn append
        guard record.slotStart + UInt64(record.slotCount) <= durableSlotCount else { continue }
        guard record.slotCount <= record.pieceCount else { continue }
        valid.append(record)
    }
    truncatePartialTrailingRecord(generation.documents)   // file length not a multiple of 64

    // --- pass 2: fold, last valid record per uuid wins ---
    ranges = [:]
    for record in valid.sorted(by: { $0.seq < $1.seq }) {
        ranges[record.uuid] = record.live ? DocumentRange(record) : nil
    }
    nextSeq = (valid.map(\.seq).max() ?? 0) + 1

    try reconcile(against: dbPool)
}
```

### reconcile — the part that makes Rule 1 safe

Without this, a crash between SQLite's commit and the index write leaves a document permanently FTS-searchable but never semantically searchable, and a crash on the delete path leaks slots that compaction never reclaims because `deadCount` was never incremented.

```
func reconcile(against dbPool) throws {
    let inSQLite: Set<UUID> = SELECT uuid FROM documents
    let inIndex = Set(ranges.keys)

    // Index is behind SQLite: rows exist, vectors don't. Text is still in SQLite, so re-embed.
    for uuid in inSQLite.subtracting(inIndex) { needsReindex.insert(uuid) }

    // Index is ahead of SQLite: zombie vectors that score but resolve to a dead rowid.
    for uuid in inIndex.subtracting(inSQLite) {
        tombstoneRange(ranges[uuid]!)          // also bumps deadCount so compaction can reclaim
        ranges[uuid] = nil
    }

    try flush()
}
```

At 50k documents this is one `SELECT` and a set difference.

---

## 7. addDocument — insert

Called by `IrisDB` *after* the SQLite transaction has committed, so `piece.id` is populated.

**The slot count comes from this routine, never from `document.pieces.count`.** `add(pieces:)` skips pieces with empty embeddings, and image pieces have empty embeddings. Record a 10-piece document with `slotCount = 10` when only 7 were embedded, and `search(within:)` scans three slots belonging to the *next* document and returns another document's text inside this document's `SearchResult`. Every value involved is structurally legal, so no validation catches it.

```
func addDocument(document: IrisDocument) throws {   // synchronous. no await, anywhere.
    // 1. Collect only what is actually embeddable. THIS defines slotCount.
    var vectors: [[Float]] = []
    var ids: [UInt64] = []
    for piece in document.pieces where !piece.embeddings.isEmpty {
        guard let pieceID = piece.id else { continue }
        guard piece.embeddings.count == dimensions else { throw .invalidVectorDimension }
        var v = piece.embeddings
        normalizeL2(&v)                       // preserves today's cosine-as-inner-product semantics
        guard v.isFinite && v.norm > 0 else { continue }   // reject zero/NaN: a 0-norm row scores 0.0,
                                                           // which outranks every negative cosine
        vectors.append(v); ids.append(UInt64(pieceID))
    }
    let n = vectors.count                      // ← the real slot count
    if n == 0 { return }                       // image-only document; nothing to index

    // 2. Reserve. Synchronous, so no other writer can observe the same start.
    let start = pendingSlotCount
    try faultInjector?(.afterReserve)

    // 3. Grow. map.bin FIRST — it is tiny, and a crash between the two ftruncates must never
    //    leave the map smaller than the vectors file.
    if start + n > generation.capacity {
        let newCapacity = max(start + n, generation.capacity * 2)
        try generation.map.grow(to: newCapacity)          // ftruncate + republish MappedRegion
        try generation.vectors.grow(to: newCapacity)
    }

    // 4. Write payload. pwrite to the fd; the mapping stays read-only.
    try generation.vectors.write(vectors, atSlot: start)
    try faultInjector?(.afterVectorWrite)
    try generation.map.write(ids, atSlot: start)
    try faultInjector?(.afterMapWrite)

    // 5. Append the document record.
    let record = Record(uuid: document.uuid, documentID: document.id, slotStart: start,
                        slotCount: n, pieceCount: document.pieces.count,
                        seq: nextSeq, live: true)
    try generation.documents.append(record)
    nextSeq += 1

    // 6. Publish in memory. Readers see it now; durability comes at flush.
    pendingSlotCount = start + UInt64(n)
    ranges[document.uuid] = DocumentRange(record)
    appendsSinceFlush += 1

    if appendsSinceFlush >= flushThreshold { try flush() }
}
```

### flush — the commit point

```
func flush() throws {
    guard pendingSlotCount != durableSlotCount else { return }

    // Payload ordered ahead of the count. Plain fsync, ~0.033 ms each — see §2 for why this is
    // the right primitive here and F_FULLFSYNC is not.
    Durability.sync(generation.vectors.fd)
    Durability.sync(generation.map.fd)
    Durability.sync(generation.documents.fd)
    try faultInjector?(.beforeSlotCountBump)

    try generation.map.writeHeaderSlotCount(pendingSlotCount)   // ← THE COMMIT
    Durability.sync(generation.map.fd)
    try faultInjector?(.afterSlotCountBump)

    durableSlotCount = pendingSlotCount
    appendsSinceFlush = 0
}
```

On close: `flush()`, then `Durability.fullSync(generation.map.fd)`, then set `cleanShutdown`. That is the one place per session where paying 4.6 ms is worth it.

**Pick `flushThreshold` deliberately.** Everything appended since the last flush is invisible after a crash, and because vectors are not recoverable from SQLite, recovery means re-embedding those documents. Flushing every ~32 documents keeps the fsync cost amortised while bounding the re-embed window to something a user would not notice. Always flush before compaction, before close, and at the end of a batch ingest.

---

## 8. removeDocument

Ordering is the mirror of insert: make the *index* side durable first, because it is idempotent and cheap, so the surviving crash window is the recoverable direction.

```
func removeDocument(documentID uuid: UUID) throws {
    guard let range = ranges[uuid] else { return }   // already gone; idempotent

    // Contiguity is why this is one write instead of N lookups.
    try generation.map.tombstone(range.slotStart ..< range.slotStart + range.slotCount)
    try generation.documents.append(Record(uuid: uuid, ..., seq: nextSeq, live: false))
    nextSeq += 1
    generation.map.deadCount += range.slotCount
    ranges[uuid] = nil

    try flush()

    // vectors.bin is NOT touched. ~1 KB written instead of a 289 MB rewrite.
    if Double(deadCount) / Double(pendingSlotCount) > 0.25 { scheduleCompaction() }
}
```

`pieceIDs` is no longer needed — the range comes from `documents.bin` by uuid. Keep the parameter while `FaissIndex` still conforms, then drop it and delete the extra SQLite fetch it forces in `performDeleteDocument`.

## 9. update

`IrisDB.performUpdateDocument` already calls `removeDocument` then `addDocument`. Reverse them:

```
addDocument(newDocument)      // appends a new contiguous range, flushes, slotCount now durable
removeDocument(uuid: old)     // only now tombstone the old range
```

Tombstoning first and crashing before the new range is durable leaves the document with no live range at all. Appending first means the worst case is two live ranges for one uuid, and last-valid- wins resolves that deterministically at open.

---

## 10. search — tiled scan

`cblas_sgemv` is `API_DEPRECATED` since macOS 13.3 and takes 32-bit `M`/`lda`; `M * lda` overflows `INT32_MAX` at 5M rows × 512d. It is also single-threaded on a memory-bound kernel. Tiling fixes the ceiling, the parallelism, and the working set at once. Build with `-DACCELERATE_NEW_LAPACK`.

```
func search(query: [Float], kItems k: Int) throws -> [(id: Int, distance: Float)] {
    var q = query; normalizeL2(&q)

    let rows = Int(pendingSlotCount)          // ← NOT capacity. ftruncate zero-fills, and a zero
                                              //   vector scores exactly 0.0, outranking every
                                              //   legitimately negative cosine.
    if rows == 0 { return [] }

    let region = generation.vectors.region    // retain ONCE, synchronously. The scan may outlive a
                                              // growth; the old mapping stays alive via this ref.
    let tileRows = 262_144
    let tiles = stride(from: 0, to: rows, by: tileRows)

    // Dead slots consume the top-k budget, so widen by the dead fraction before selecting.
    let deadFraction = Double(generation.map.deadCount) / Double(rows)
    let widened = Int(Double(k) * (1.0 + deadFraction)) + 1

    var perTile = [TopK?](repeating: nil, count: tiles.count)
    DispatchQueue.concurrentPerform(iterations: tiles.count) { t in
        let start = t * tileRows
        let m = min(tileRows, rows - start)
        var scores = [Float](repeating: 0, count: m)

        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                    Int32(m), Int32(dimensions),
                    1.0, region.floats(atSlot: start, dimensions: dimensions, count: m).baseAddress,
                    Int32(dimensions), q, 1, 0.0, &scores, 1)

        var heap = TopK(capacity: widened)
        for i in 0..<m {
            let slot = start + i
            guard generation.map[slot] != UInt64.max else { continue }   // skip tombstones DURING
                                                                        // selection, not after
            guard scores[i].isFinite else { continue }                  // a torn page can yield NaN,
                                                                        // and NaN comparisons are all
                                                                        // false — it would sit atop
                                                                        // the heap and evict everything
            heap.insert(slot: slot, score: scores[i])
        }
        perTile[t] = heap
    }

    // Merge, then translate only the survivors. Tie-break: lowest slot wins (document this —
    // FAISS breaks ties by internal id, so ordering will differ on exact ties).
    return TopK.merge(perTile, k: k).map { (id: Int(generation.map[$0.slot]), distance: $0.score) }
}
```

Filtering tombstones *after* selecting the top k is the trap: delete every document but one and a query returns zero results instead of one. Write that test first and let it force the structure.

## 11. search(within:)

```
func search(query: [Float], kItems k: Int, collection uuid: UUID) throws -> [(id: Int, distance: Float)] {
    guard let range = ranges[uuid] else { return [] }
    // Same kernel, bounded to one contiguous sub-matrix. O(document), not O(corpus).
    return scan(query: query, slots: range.slotStart ..< range.slotStart + range.slotCount, k: k)
}
```

This is what replaces the 2,001 per-document `.index` files.

---

## 12. compaction — two phase

Compaction rewrites gigabytes and cannot hold the actor. Anything appended while it runs would be silently discarded by the `current` rename — no error, no tombstone, and SQLite still believes those documents are indexed.

```
func compact() throws {
    guard !compactionInProgress else { return }      // two writers must not build into one path
    compactionInProgress = true; defer { compactionInProgress = false }
    try flush()

    // --- phase 1: off-actor, unbounded work over a frozen prefix ---
    let snapshot = pendingSlotCount
    let next = generation.number + 1
    let dir = root/"index-\(next)"
    buildCompacted(from: generation, slots: 0..<snapshot, into: dir)   // live slots only, renumbered,
                                                                      // document-by-document so ranges
                                                                      // stay contiguous
    Durability.fullSync(dir.vectors.fd); Durability.fullSync(dir.map.fd); Durability.fullSync(dir.documents.fd)
    Durability.syncDirectory(dir)

    // --- phase 2: back on the actor, synchronous, no await from here to the rename ---
    replay(slots: snapshot ..< pendingSlotCount, into: dir)   // bounded and small
    dir.map.writeHeaderSlotCount(newCount)
    Durability.fullSync(dir.map.fd)

    try faultInjector?(.beforeCurrentRename)
    atomicallyReplaceCurrentPointer(naming: next)   // write current.tmp, rename → THE COMMIT
    Durability.syncDirectory(root)
    try faultInjector?(.afterCurrentRename)

    generation = Generation.open(dir)
    ranges = foldRanges(dir.documents)              // slot numbers all changed
    deleteGeneration(number: next - 1)              // if this is interrupted, open() sweeps it
}
```

---

## 13. Fault-injection points

Build these into the write path from the start. Retrofitting means rewriting it twice, and the runtime cost is one nil check per write.

```
enum FaultPoint { case afterReserve, afterVectorWrite, afterMapWrite, afterRecordAppend,
                       beforeSlotCountBump, afterSlotCountBump,
                       beforeCurrentRename, afterCurrentRename }
```

For each point: build a fixture, install an injector that throws there, attempt the operation, close, reopen, and assert

- `slotCount` is either the pre- or the post-operation value, never in between;
- every surviving record satisfies `slotStart + slotCount <= slotCount`;
- top-k returns exactly the pre-operation document set or exactly the post-operation set, never a mix;
- re-running the same operation after recovery succeeds and produces no duplicate.

True power loss is not reproducible in-process. The fsync ordering in §2 and §7 is reasoned, not tested — say so in the test file header so nobody later assumes coverage that does not exist.

---

## 14. Invariant checklist

Assert these at open, and in a debug-only `validate()` the tests call after every mutation.

1. `slotCount <= capacity`, and `capacity == (fileSize - headerSize) / (d * 4)` for `vectors.bin`.
2. `vectors.bin` and `map.bin` report the same capacity.
3. `vectors.bin.dimensions == embeddingProvider.dimension`.
4. Every live range is disjoint from every other live range.
5. For every live range, no slot in it is tombstoned in `map.bin`.
6. `deadCount == count of tombstoned slots in [0, slotCount)`.
7. `slotCount <= pieceCount` for every record.
8. `ranges.keys` equals the live uuid set in SQLite (post-reconcile).
9. Every record offset is a multiple of 64 and the file length is a multiple of 64.

Optional, worth it if a corrupted index ever shows up in the field: a per-page CRC32 sidecar for `vectors.bin`. It is the only copy of every embedding and has no integrity check, so a torn page becomes plausible float garbage. Detection is enough — `textContent` survives in SQLite, so `rebuildIndex()` is always available as the escape hatch.
