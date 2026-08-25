<!-- Authored by Claude Opus 5 (Anthropic) on 2026-08-13 -->

# Accelerate vector index — implementation pseudocode

Companion to the design decisions in the planning session. Pseudocode is Swift-flavoured but not compilable: it omits error plumbing and most bounds checks so the *ordering* stays visible, because the ordering is the part that is hard to get right and impossible to test after the fact.

Read §1 and §6 first. Everything else is mechanical; those two are where the correctness lives.

---

## 0. Type map

| Type | File | Responsibility |
| --- | --- | --- |
| `BinaryFile` | `Vector Index/Accelerate/BinaryFile.swift` | Wraps one `FileHandle`. The cursor lives here and nowhere else. |
| `Durability` | `Vector Index/Accelerate/Durability.swift` | `sync()` via Foundation; `fullSync()`/`syncDirectory()` are Darwin shims |
| `VectorFile` | `Vector Index/Accelerate/VectorFile.swift` | `[capacity × d]` float32 matrix. Mapped for reads, `BinaryFile` for writes |
| `SlotMap` | `Vector Index/Accelerate/SlotMap.swift` | slot → piece rowid; **owns the authoritative `slotCount`** |
| `DocumentMap` | `Vector Index/Accelerate/DocumentMap.swift` | the *fold* of the document log: one live range per uuid |
| `DocumentLog` | `Vector Index/Accelerate/DocumentLog.swift` | the append-only file of 64-byte records; owns a `DocumentMap` |
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
    await sync()               // ← actor released here; the other create now reads the same start
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

- **Process death** (jetsam, force quit, `SIGKILL`, an uncaught crash) — the page cache is in the kernel and survives. Everything already written is visible to the next process. **No sync is needed at all.** This is overwhelmingly the most likely way the app dies.
- **Kernel panic** — page cache lost. Plain `fsync` covers it, for 0.033 ms.
- **Power loss** — the device write cache is lost too. Only `F_FULLFSYNC` covers it, for 4.6 ms.

The reason to sync at all is **ordering, not durability**. Without it, a flush can land the page holding `slotCount` while the pages holding the vector data are still dirty. You reopen to a live slot whose vectors were never written — zeros, which score exactly `0.0` and therefore outrank every legitimately negative cosine, surfacing near the top of results and resolving to a real piece rowid. Missing data is recoverable (§6 reconciles it into a re-embed); a live slot pointing at unwritten bytes is silently wrong forever.

```
enum Durability {
    // Hot path. Ordering + kernel-panic safety for 0.033 ms. Call on the payload files
    // BEFORE writing the header; sync(A) returning before sync(B) is called orders A ahead of B.
    // Foundation, typed, portable.
    static func sync(_ handle: FileHandle) throws { try handle.synchronize() }

    // Power-loss durability. 4.6 ms — reserve it for compaction commit and clean shutdown,
    // where it happens once rather than once per batch.
    //
    // Darwin-only BECAUSE Darwin's fsync does not flush the device write cache. Linux's does,
    // so `synchronize()` above is already the strong version there. This is a workaround for a
    // platform weakness, not a portability hole.
    static func fullSync(_ handle: FileHandle) throws {
        #if canImport(Darwin)
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else { throw Errno.current }
        #else
        try handle.synchronize()
        #endif
    }

    // A rename is not durable until the containing directory is synced, and Foundation has no
    // API for opening a directory.
    static func syncDirectory(_ url: URL) throws { ... }
}
```

**The complete non-Foundation surface, three calls:**

| call | why Foundation cannot | ports to |
| --- | --- | --- |
| `fcntl(F_FULLFSYNC)` | no API; Darwin's `fsync` is weak | Darwin only — and only *needed* on Darwin |
| directory `fsync` | Foundation cannot open a directory | POSIX |
| `flock(LOCK_EX\|LOCK_NB)` | no advisory-locking API at all | POSIX (macOS, Linux; not Windows) |

Everything else — mapping, reading, writing, growth, rename, plain `fsync` — is Foundation. Keep these
three behind `Durability` and the writer-lock helper so the rest of the index never imports `Darwin`.

**Plus a dirty bit, which is what turns "we hope the ordering held" into "we check."** Carry `cleanShutdown: Bool` in `map.bin`'s header: clear it on the first write after open, set it on close. If `open()` finds it clear, the process did not shut down cleanly — run the §6 reconcile unconditionally rather than trusting the tail of the log. This is the same trick filesystems use, and it costs nothing on the normal path.

Writes go through `FileHandle`, **not** through the mapping, which stays read-only. That removes any need for `msync` and keeps the reader and writer paths independent: a scan holding a pointer into the mapping cannot be disturbed by a concurrent write elsewhere in the file.

`FileHandle` has no positional write, so `BinaryFile` does `seek(toOffset:)` then `write(contentsOf:)`. Two calls against a shared cursor, which is safe **only because one actor owns the writer** — that discipline is now load-bearing rather than incidental. Contain the cursor inside `BinaryFile` so no call site can observe it.

---

## 3. The mapping

`vectors.bin` is mapped with Foundation. There is no hand-rolled region type.

```
let mapping = try Data(contentsOf: vectorsURL, options: .alwaysMapped)
```

**Use `.alwaysMapped`, not `.mappedIfSafe`.** The latter silently falls back to a *full read* when the
volume is not deemed safe, which on a multi-GB index is a resident allocation large enough to get the
app jetsammed. `.alwaysMapped` maps unconditionally. Measured on an 800 MB file: footprint 1.7 MB before
mapping, 1.7 MB after mapping, 2.1 MB after touching one byte per 4 MB — genuinely lazy, no fallback.

**ARC gives you the lifetime discipline for free.** An earlier draft hand-rolled a refcounted
`MappedRegion` so that a scan in flight could not have its memory `munmap`ed by a concurrent growth.
`Data` is a value type whose mapped backing store is already reference-counted, so holding a `Data`
across a scan *is* the retain. Growth reads a new `Data` from the resized file; the old mapping is
released when the last in-flight scan drops its copy. Same guarantee, none of the code.

The one adjustment: BLAS needs a raw pointer, and `Data` only vends one inside a closure. So the whole
tiled scan runs inside a single `withUnsafeBytes`. That is a better shape than the hand-rolled version
anyway — the pointer provably cannot outlive the scope, enforced by the compiler rather than by
convention.

```
try mapping.withUnsafeBytes { raw in
    let base = raw.baseAddress!.advanced(by: VectorFile.headerSize)
                               .assumingMemoryBound(to: Float.self)
    // ... every tile of the scan, then top-k, all inside this closure ...
}
```

**The mapping is `MAP_PRIVATE`, so it does not see writes made through the file handle.** This is the
single most surprising property of the design and it is load-bearing: a scan must see vectors written
earlier in the same session, and it will not. Measured on Darwin — write four bytes through a
`FileHandle`, read the same offset through an existing `.alwaysMapped` `Data`:

```
1. page not faulted before the write:  STALE
2. page faulted before the write:      STALE
3. append past EOF: mapping.count UNCHANGED — growth is invisible
5. 64 write-after-read pages:          64 stale, 0 visible
```

Not "sometimes", not "under memory pressure" — never, 64 out of 64. Re-reading the file picks
everything up. So **`VectorFile.write` must remap before it returns**, not only `grow`:

```
try file.write(data: Data(raw), at: byteOffset(ofSlot: start))
try remap()          // REQUIRED. Without it every freshly written vector scores 0.0 against
                     // the zero-fill that was there when the mapping was taken.
```

The cost is address-space bookkeeping, not I/O, because `mmap` is lazy: **0.13 ms on an 88 MB file**,
against the milliseconds of embedding that produced those vectors. Do not try to defer it to `flush` —
readers see a document the moment `slotMap.count` advances, which is before the flush.

Two assumptions worth asserting once rather than trusting: the mapped `Data` is contiguous (true for a
mapped file, so `withUnsafeBytes` does not flatten and copy), and `VectorFile.headerSize` is
page-aligned so the matrix base is too.

---

## 4. Headers and records

Keep the existing `StorageHeader` protocol and version-byte dispatch. Fix the three prototype bugs by construction: magic is bytes not a `String`, `byteSize` is a literal the layout is asserted against, and the version is read from offset 4 (after the magic), not offset 0.

**Byte order, and what it costs in portability.** Metadata in `map.bin` and `documents.bin` is
little-endian: those files materialise through `store`/`load`, where the swap is free and stating the
contract in code is worth doing. `vectors.bin` is **host byte order** and cannot be otherwise — its
bytes go straight to Accelerate out of a mapping, and swapping them would mean materialising the whole
matrix, the one thing this design forbids. So the index is *not* portable across endianness, and the
failure would be silent: headers parse, then every distance comes back as nonsense. Every target that
matters is little-endian; write this down rather than let the careful `.littleEndian` in the metadata
imply a portability that does not exist.

```
// vectors.bin — header padded to a page so the matrix base is page-aligned.
VectorFile.headerSize = 4096
  0   magic       "IRIS"  (4 bytes, literal 0x49 0x52 0x49 0x53)
  4   version     u8 + 3 pad
  8   dimensions  u64
  16  generation  u64          // must match the sibling files
  24… reserved, zeroed
  4096 vectors: capacity × d × 4, row-major.  Slot i at 4096 + i*d*4
       capacity is DERIVED: (fileSize - 4096) / (d * 4). Write-once header, so no CRC.

// map.bin — random access at k offsets, never streamed, so one cache line of header is enough.
SlotMapFile.headerSize = 64
  0   magic       "IMAP"
  4   version     u8 + 3 pad
  8   slotCount     u64   ← THE AUTHORITATIVE COUNT AND THE COMMIT POINT.
                            Built from `entries.count` when the header is encoded, NOT stored on
                            the in-memory Header — a stored copy must be re-synced by every write
                            path, which is the bug `cachedPieceCount` already taught us.
  16  generation    u64
  24  cleanShutdown u8 + 3 pad
  28  crc32         u32   // over bytes 0..<28
  32… reserved, zeroed
  64  entries: capacity × u64.  UInt64.max = tombstone.
      capacity is DERIVED: (fileSize - 64) / 8.
      deadCount is DERIVED: counted during the load pass, which already touches every entry.
      THE ONLY HEADER REWRITTEN IN NORMAL OPERATION — hence the only one carrying a CRC.

// documents.bin — append-only log. Read once at open, appended thereafter. NEVER mmap'd,
// so it has no capacity and is never pre-grown. Header is write-once, so no CRC.
DocumentLogFile.headerSize = 64, recordSize = 64
// Offset convention, because the two halves disagree and it is not guessable:
//   `load(at:)`  is RELATIVE to startIndex — it rebases, so pass the bare field offset.
//   `store(at:)` and array subscripts are ABSOLUTE — they need `base` added.
// So a header decoder reads `bytes.load(at: Offset.version)` but slices
// `bytes[base ..< base + magic.count]`. Adding `base` to a load counts startIndex twice: inert
// while the parameter is `[UInt8]`, wrong the moment it is a slice.
// A *record* decoder is the exception — its `base` is a record offset inside the buffer rather
// than a startIndex, so `load(at: base + Offset.x)` is correct there.
  header:
    0   magic       "IDOC"
    4   version     u8 + 3 pad
    8   generation  u64
    16… reserved, zeroed
    64  records begin.  recordCount is DERIVED: (fileSize - 64) / 64.

  record (64 B — sized so none straddles a 4096 B page, which bounds a torn
          append to exactly one record for the CRC to catch):
    0   uuid        16 bytes
    16  documentID  u64      // SQLite rowid, equals document_pieces.parentID
    24  slotStart   u64
    32  slotEnd     u64      // EXCLUSIVE. Range is [slotStart, slotEnd).
    40  seq         u64      // monotonic; makes "last record wins" well-defined
    48  flags       u32      // bit 0 = live. See below — this is not redundant with an empty range.
    52  crc32       u32      // over bytes 0..<52
    56  reserved    8 bytes
```

**Why `slotEnd` and not `slotCount`.** Validation runs on untrusted bytes, and `start + count <= slotCount`
can overflow — in Swift that *traps*, turning a corrupt record into a crash during recovery. `start <= end
&& end <= slotCount` is two comparisons with no arithmetic at all. The consumers prefer it too: every use is
a slice, and `start ..< end` is already a `Range` where `start ..< start + count` repeats the addition at
every call site.

**Why `flags` is not redundant with an empty range.** It is tempting to let `slotStart == slotEnd` mean
deleted. It cannot, because a live document can legitimately own zero slots — `add(pieces:)` skips pieces
with empty embeddings, so an image-only document embeds nothing. Without a flag, reconcile (§6) sees that
document in SQLite but not live in the log, queues it for re-index, gets zero vectors again, and repeats
that on **every subsequent open** — an unbounded re-embed loop for image-only documents. The flag is what
separates "deleted" from "live with nothing embeddable."

**There is no `pieceCount`.** An earlier draft stored it to assert `slotCount <= pieceCount` as a defence
against taking the count from `document.pieces.count`. That assertion cannot catch that bug: if you made
the mistake, the two values are equal and the check passes. It also duplicates something SQLite already
owns. The real defence is structural — see §7.

`UInt64.max` is safe as a tombstone: piece rowids are `INTEGER PRIMARY KEY AUTOINCREMENT`, so always positive and **never reused**. Preserve that property — it is what stops a leaked map entry from ever aliasing a future piece.

---

## 5. AccelerateIndex state

```
final class AccelerateIndex: VectorIndex {     // final class, NOT an actor, NOT Sendable
    private let root: URL                       // main.irisdb/vector-index
    private let dimensions: Int
    private var generation: Generation          // the three open files + their mapping
    private var lockFD: Int32                   // flock(LOCK_EX|LOCK_NB) on writer.lock

    // Group commit: the in-memory count runs ahead of the durable one. Only the durable one is
    // stored — the in-memory count IS `generation.map.count`, and a second copy of it is the
    // `cachedPieceCount` shape: two variables for one fact, updated by different code paths.
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

    // Capacity is derived from file length in both files — neither stores it, so they cannot
    // disagree about a number neither one holds. They CAN have different lengths if a crash
    // landed between the two ftruncates, so take the min and re-grow.
    let capacity = min(generation.vectors.derivedCapacity, generation.map.derivedCapacity)
    try growBoth(to: capacity)

    // Clamp rather than trust. A torn header write can yield a garbage slotCount; if it reads
    // large, an unclamped scan runs off the end of the mapping. This is the check that actually
    // protects you — the header CRC protects your ability to trust `cleanShutdown`.
    // Loading the slot map reads exactly `slotCount` entries, so `generation.map.count` is the
    // in-memory count from here on. deadCount is not stored either — tombstones are counted during
    // that same load pass, which already touches every entry, so it cannot inherit drift.
    durableSlotCount = min(generation.map.slotCount, capacity)

    let wasClean = generation.map.cleanShutdown
    try generation.map.clearCleanShutdown()   // set again only on an orderly close

    // --- pass 1: validate each record on its own merits ---
    var valid: [Record] = []
    for record in generation.documents.records() {
        guard record.crcValid else { continue }                            // torn append
        guard record.slotStart <= record.slotEnd else { continue }        // no arithmetic on
        guard record.slotEnd <= durableSlotCount else { continue }        // untrusted bytes.
                                                                          // This is exactly the
                                                                          // `maximumSlotCount`
                                                                          // parameter DocumentMap
                                                                          // takes at decode.
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

**The range comes from this routine, never from `document.pieces.count`.** `add(pieces:)` skips pieces with empty embeddings, and image pieces have empty embeddings. Record a 10-piece document as owning 10 slots when only 7 were embedded, and `search(within:)` scans three slots belonging to the *next* document and returns another document's text inside this document's `SearchResult`. Every value involved is structurally legal, so no validation catches it — and no stored invariant can, either, because the wrong value equals the piece count exactly.

**The defence is structural, not an assertion.** Have the write routine *return the range it wrote*, and have the record initialiser take that range rather than taking an `IrisDocument`. Then there is no parameter for `pieces.count` to be passed into and the mistake is unrepresentable. Back it with one test: index a document containing image pieces, index a second, and assert the second's range begins exactly where the first ended and that `search(within:)` on the first never returns a piece belonging to the second.

```
func addDocument(document: IrisDocument) throws {   // synchronous. no await, anywhere.
    // 1. Collect only what is actually embeddable. THIS defines the range.
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
    let n = vectors.count
    // NOTE: no early return when n == 0. An image-only document owns an EMPTY range and is still
    // LIVE. Skip the record and reconcile (§6) sees it in SQLite but not in the log, queues it for
    // re-index, gets zero vectors again, and repeats on every subsequent open — forever.

    // 2. Grow to EXACTLY what is needed — no doubling. Capacity is derived from file length.
    //    map.bin FIRST: it is tiny, and a crash between the two ftruncates must never leave the
    //    map smaller than the vectors file.
    //
    //    Doubling is the array-resize reflex and it does not apply here, because ftruncate copies
    //    nothing. Measured, truncate + remap is 0.027 ms and FLAT from 1 MiB to 8 GiB — mmap is
    //    lazy and truncate is a metadata update, so there is nothing to amortise. Growth also
    //    allocates zero physical blocks (8272 MiB logical read 0 MiB physical on APFS), so
    //    over-allocating reserves nothing; it only inflates the logical size that backup tooling
    //    and iOS storage accounting report. A 2.9 GB index showing as 5.8 GB in Settings, to save
    //    0.027 ms per document, is the wrong trade.
    let start = generation.map.count            // NOT a stored counter. See §5.
    try faultInjector?(.afterReserve)
    if start + n > generation.derivedCapacity {
        try generation.map.grow(to: start + n)            // truncate(atOffset:) + re-read the mapping
        try generation.vectors.grow(to: start + n)
    }

    // `grow` must refuse to shrink. `truncate(atOffset:)` shortens a file as happily as it extends
    // one, and here shortening discards committed vectors.

    // 3. Write payload through BinaryFile; the mapping stays read-only. ONE call writes both files,
    //    so there is no second position parameter for them to disagree about — the slot map
    //    allocates and the vector file follows its range. It RETURNS the range it wrote, so the
    //    record is built from the return value and never from the document. Both mistakes —
    //    pieces.count, and the two files drifting apart — become unrepresentable rather than
    //    asserted against.
    //
    //    func writePayload(vectors:ids:) -> Range<Int> {
    //        precondition(vectors.count == ids.count)
    //        let slots = map.append(contentsOf: ids)              // allocates
    //        try self.vectors.write(vectors: vectors, at: slots.lowerBound)   // follows, then remaps
    //        return slots
    //    }
    let slots: Range<Int> = try generation.writePayload(vectors: vectors, ids: ids)
    try faultInjector?(.afterMapWrite)

    // 4. Append the document record, built from `slots`. The log mints the sequence from its own
    //    `nextSequence` — callers never pass one, so a duplicate seq (which makes last-write-wins a
    //    coin flip) is unrepresentable. `map.apply` advances the counter; there is no `nextSeq += 1`.
    try generation.documents.append(uuid: document.uuid, documentID: document.id,
                                    slots: slots, live: true)

    // 5. Publish in memory. Readers see it now; durability comes at flush. There is nothing to
    //    assign — `map.append` in step 3 already advanced the count readers scan.
    appendsSinceFlush += 1

    if appendsSinceFlush >= flushThreshold { try flush() }
}
```

### flush — the commit point

```
func flush() throws {
    guard generation.map.count != durableSlotCount else { return }

    // Payload ordered ahead of the count. Plain fsync, ~0.033 ms each — see §2 for why this is
    // the right primitive here and fullSync is not.
    Durability.sync(generation.vectors.fd)
    Durability.sync(generation.map.fd)
    Durability.sync(generation.documents.fd)
    try faultInjector?(.beforeSlotCountBump)

    try generation.map.writeHeader()             // ← THE COMMIT. slotCount is built from
    Durability.sync(generation.map.fd)           //   map.count at encode time, not stored.
    try faultInjector?(.afterSlotCountBump)

    durableSlotCount = generation.map.count
    appendsSinceFlush = 0
}
```

On close: `flush()`, then `Durability.fullSync(generation.map.fd)`, then set `cleanShutdown`. That is the one place per session where paying 4.6 ms is worth it.

**Pick `flushThreshold` deliberately.** Everything appended since the last flush is invisible after a crash, and because vectors are not recoverable from SQLite, recovery means re-embedding those documents. Flushing every ~32 documents keeps the fsync cost amortised while bounding the re-embed window to something a user would not notice. Always flush before compaction, before close, and at the end of a batch ingest.

---

## 8. removeDocument

Ordering is the mirror of insert: make the *index* side durable first, because it is idempotent and cheap, so the surviving crash window is the recoverable direction.

```swift
func removeDocument(documentID uuid: UUID) throws {
    guard let range = ranges[uuid] else { return }   // already gone; idempotent

    // Contiguity is why this is one write instead of N lookups.
    try generation.map.tombstone(range)                  // range is already [start, end)
    try generation.documents.append(Record(uuid: uuid, ..., seq: nextSeq, live: false))
    nextSeq += 1
    generation.map.deadCount += range.countOfLive   // count what was LIVE, not range.count — an unconditional += double-counts a repeated tombstone (reconcile, or a retried delete)
    ranges[uuid] = nil

    try flush()

    // vectors.bin is NOT touched. ~1 KB written instead of a 289 MB rewrite.
    // `deadFraction` returns 0 on an empty map, so the 0/0 → NaN guard lives inside SlotMap
    // rather than being re-derived (and forgotten) at each call site.
    if generation.map.deadFraction > 0.25 { scheduleCompaction() }
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

**Use `vDSP_dotpr` per row, not `vDSP_mmul` / `cblas_sgemv` — but know the crossover.** Measured at 768
dimensions with back-to-back searches and no eviction, which is the real access pattern:

```
   1024 rows    3 MiB   mmul 110.1 GB/s   dotpr 41.7 GB/s   MMUL  2.64x
   4096 rows   12 MiB   mmul  64.8 GB/s   dotpr 39.6 GB/s   MMUL  1.64x
   8192 rows   24 MiB   mmul  45.6 GB/s   dotpr 40.0 GB/s   MMUL  1.14x
  16384 rows   48 MiB   mmul  35.9 GB/s   dotpr 39.7 GB/s   dotpr 1.11x
  24000 rows   70 MiB   mmul  31.5 GB/s   dotpr 39.6 GB/s   dotpr 1.26x
  30000 rows   87 MiB   mmul  30.3 GB/s   dotpr 39.5 GB/s   dotpr 1.30x
  60000 rows  175 MiB   mmul  30.1 GB/s   dotpr 39.5 GB/s   dotpr 1.31x
```

Identical scores from both. `cblas_sgemv` tracks `vDSP_mmul` within noise at every size.

**The crossover is the last-level cache, not warm-vs-cold.** It lands at 48 MiB, exactly the M1 Max
SLC. `vDSP_mmul` is a general `M×K` by `K×N` multiply, blocked so a block of the left matrix is reused
across columns of the right. This call is `N×768` by `768×1` — **one column, so the only reuse available
is across repeated searches, and that requires the matrix to stay resident.** Above the cache size it is
streaming from DRAM, the blocking is pure cost, and throughput collapses from 110 to 30 GB/s. `dotpr`
reads a row front to back and accumulates: nothing to block, nothing to reorder, a flat 39.5 GB/s at
every size measured, cold or warm.

**Why `dotpr` anyway.** `mmul` wins 2.64× at 1,024 vectors, where the scan is 0.03 ms and imperceptible.
`dotpr` wins 1.31× at 60,000, where the scan is 4.7 ms and the saving is 1.5 ms per query. The advantage
is concentrated where the scan is already invisible; the disadvantage is where it costs something. If
corpora will stay in the low thousands of vectors permanently, reverse this — and on a base M1 (8–12 MB
SLC) the crossover drops to ~3–4k vectors, so it is machine-dependent as well as corpus-dependent.

**Dimension matters too.** `mmul` wins decisively below ~256 dimensions (1.4× at 128 and 256, 3.06× at
64), where rows get short enough that `dotpr`'s per-call overhead dominates — 356,000 calls at 64d.
From 320 up, `dotpr` leads at every dimension measured. `dimensions` comes from `embeddingProvider` at
runtime, so a future model could land in that range: BGE-small is 384 and Apple's contextual embedding
is 512, both comfortably on the `dotpr` side.

Both kernels are single-threaded on a memory-bound problem, so tiling is still what buys parallelism
and a bounded working set.

**Per-row tombstone skipping was considered and rejected.** Skipping the dot product for dead slots
sounds free once you are already looping, but it breaks sequential prefetch — measured at 50% dead:
`0.86×` for scattered singles, `1.42×` for runs of 10, `1.87×` for runs of 64. With compaction
triggering at 25%, dead runs stay short and the win is marginal at best and a regression at worst.
Score every row; filter during selection.

```swift
func search(query: [Float], kItems k: Int) throws -> [(id: Int, distance: Float)] {
    var q = query; normalizeL2(&q)

    let rows = generation.map.count           // ← NOT capacity. ftruncate zero-fills, and a zero
                                              //   vector scores exactly 0.0, outranking every
                                              //   legitimately negative cosine.
    if rows == 0 { return [] }

    let mapping = generation.vectors.mapping  // retain ONCE, synchronously. A concurrent growth
                                              // publishes a NEW Data; this copy keeps the old
                                              // mapping alive for the duration of the scan.
    // Everything below runs inside `mapping.withUnsafeBytes { raw in ... }`, with
    // `matrixBase = raw.baseAddress! + VectorFile.headerSize` bound to Float. The closure scope is
    // what makes the pointer's lifetime checkable by the compiler instead of by convention.
    let tileRows = 262_144
    let tiles = stride(from: 0, to: rows, by: tileRows)

    // No widening. Dead slots would consume the top-k budget only if they entered the heap, and
    // the `isLive` guard below runs before `insert`. Widening here is a leftover from a design
    // that filtered after selection.
    let widened = k

    var perTile = [TopK?](repeating: nil, count: tiles.count)
    DispatchQueue.concurrentPerform(iterations: tiles.count) { t in
        let start = t * tileRows
        let m = min(tileRows, rows - start)
        var heap = TopK(capacity: widened)

        // Scoring and selection in one pass — no per-tile scores array to allocate.
        for i in 0..<m {
            let slot = start + i

            guard generation.map.isLive(slot) else { continue }   // BEFORE the multiply: skips the
                                                                  // work as well as the result, and
                                                                  // still filters DURING selection
                                                                  // rather than after
            var score: Float = 0
            vDSP_dotpr(matrixBase.advanced(by: slot * dimensions), 1,
                       q, 1, &score, vDSP_Length(dimensions))

            guard score.isFinite else { continue }                // a torn page can yield NaN, and
                                                                  // NaN comparisons are all false —
                                                                  // it would sit atop the heap and
                                                                  // evict everything beneath it
            heap.insert(slot: slot, score: score)
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
    return scan(query: query, slots: range, k: k)        // one contiguous sub-matrix
}
```

This is what replaces the 2,001 per-document `.index` files.

---

## 12. compaction — two phase

Compaction rewrites gigabytes and cannot hold the actor. Anything appended while it runs would be silently discarded by the `current` rename — no error, no tombstone, and SQLite still believes those documents are indexed.

```swift
func compact() tshrows {
    guard !compactionInProgress else { return }      // two writers must not build into one path
    compactionInProgress = true; defer { compactionInProgress = false }
    try flush()

    // --- phase 1: off-actor, unbounded work over a frozen prefix ---
    let snapshot = generation.map.count
    let next = generation.number + 1
    let dir = root/"index-\(next)"
    buildCompacted(from: generation, slots: 0..<snapshot, into: dir)   // live slots only, renumbered,
                                                                      // document-by-document so ranges
                                                                      // stay contiguous
    Durability.fullSync(dir.vectors.fd); Durability.fullSync(dir.map.fd); Durability.fullSync(dir.documents.fd)
    Durability.syncDirectory(dir)

    // --- phase 2: back on the actor, synchronous, no await from here to the rename ---
    replay(slots: snapshot ..< generation.map.count, into: dir)   // bounded and small
    dir.map.writeHeader()
    Durability.fullSync(dir.map.fd)

    try faultInjector?(.beforeCurrentRename)
    atomicallyReplaceCurrentPointer(naming: next)   // write current.tmp, rename → THE COMMIT
    Durability.syncDirectory(root)
    try faultInjector?(.afterCurrentRename)

    generation = Generation.open(dir)
    durableSlotCount = generation.map.count         // MUST be reset. Every slot was renumbered and
                                                    // the count shrank; leaving the old value makes
                                                    // the next flush a no-op and the record gate in
                                                    // §6 accept ranges past the end of the new file.
    deleteGeneration(number: next - 1)              // if this is interrupted, open() sweeps it
                                                    // (`ranges` comes back with the reopened
                                                    //  generation's DocumentMap — slots all changed)
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
- every surviving record satisfies `slotStart <= slotEnd <= slotCount`;
- top-k returns exactly the pre-operation document set or exactly the post-operation set, never a mix;
- re-running the same operation after recovery succeeds and produces no duplicate.

True power loss is not reproducible in-process. The fsync ordering in §2 and §7 is reasoned, not tested — say so in the test file header so nobody later assumes coverage that does not exist.

---

## 14. Invariant checklist

Assert these at open, and in a debug-only `validate()` the tests call after every mutation.

1. `slotCount <= min(vectors.derivedCapacity, map.derivedCapacity)`. Nothing stores capacity, so
   there is no stored-vs-derived comparison to make — only file lengths against the live count.
2. `vectors.bin.dimensions == embeddingProvider.dimension`.
3. Every live range is disjoint from every other live range.
4. For every live range, no slot in it is tombstoned in `map.bin`.
5. `deadCount == count of tombstoned slots in [0, slotCount)`. Trivially true immediately after open,
   since it is computed that way — this checks that mutations keep it true.
6. `slotStart <= slotEnd <= slotCount` for every surviving record.
7. `ranges.keys` equals the live uuid set in SQLite (post-reconcile). A live range may be **empty** —
   an image-only document — and that is not the same as a deleted one.
8. Every record offset is a multiple of 64, and the file length is a multiple of 64.
9. All three files agree on `generation`.

**No CRC over the vector matrix.** An earlier draft floated a per-page CRC32 sidecar. It does not pay:
validating it eagerly means reading every page at open, which is the laziness `.alwaysMapped` exists to provide,
and validating it lazily puts per-page work inside a scan that is already memory-bandwidth-bound. What it
would catch is small — a corrupted vector is either NaN, which §10's `isFinite` guard already rejects
before it can reach the heap, or a finite-but-wrong float, which makes exactly one row score wrong.

The principle: **checksum the small structured metadata, not the bulk data.** Metadata corruption becomes
a wrong *pointer* — silent, and it contaminates results unrelated to the damaged bytes. Bulk-data
corruption becomes one wrong *number*, bounded to the row it lives in. That asymmetry is why 4 bytes per
64-byte record is a good trade and 4 bytes per 4096-byte page is not, and it is why only `map.bin`'s
header — the one structure rewritten in normal operation — carries a checksum.
