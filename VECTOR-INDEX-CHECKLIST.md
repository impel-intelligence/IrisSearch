<!-- Authored by Claude Opus 5 (Anthropic) on 2026-08-13 -->

# Vector index — requirements checklist

A checklist to implement against and come back to. Requirements are stated as *what must be true*, not how to make it true — the how is yours.

**Cross-references:** `§n` = section in `VECTOR-INDEX-IMPLEMENTATION.md`. `F-n` = numbered finding in `PERFORMANCE-FINDINGS.md`. Phases match the plan file.

## How to use the docs together

- **This file** is the checklist. Work from it.
- **`VECTOR-INDEX-IMPLEMENTATION.md`** is reference for when a checklist item is ambiguous. It is not meant to be transcribed. If you satisfy every item here in your own way, it has done its job even if your code looks nothing like the pseudocode.
- **`PERFORMANCE-FINDINGS.md`** is the evidence — the measurements that justify why each requirement exists. Go there when an item seems like overkill.

A checklist item you disagree with is a conversation, not a mistake. Several of these exist because an earlier version of the design was wrong and got corrected.

## Phase 0 — Prep. No new index code.

- [x] **0.1** Bundle directory creation tests the path it actually creates (`IrisDB.swift:50-52`). Land this alone. Today the bundle exists only as a side effect of the FAISS constructor running before `DatabasePool` opens — make the index directory lazy and fresh installs break.
- [x] **0.2** `cachedPieceCount` adjusts per *piece*, on all three write paths including update. It feeds `searchLimit`, which becomes the `k` handed to the new scan. **F-10**
- [x] **0.3** `VectorIndex` covers both search methods; `IrisDB` holds the existential. Not `Sendable`; `IrisDB` does not become generic (it is public API the app consumes).
- [x] **0.4** One layout type owns the on-disk paths. No hardcoded `"text-index"` / `"global.index"` strings in the package, the tests, or the benchmark.
- [x] **0.5** Tests can reach a deterministic embedder with no model download.
- [ ] **0.6** Dead `SwiftFaiss` / `SwiftFaissC` imports removed.

**Done when:** the full suite passes unchanged and a benchmark run reproduces its previous numbers.

## Phase 1 — File primitives, wired to nothing. §3, §4

- [x] **1.1** Magic at offset 0; version at a fixed offset in *every* format version, forever. This is the one decision with no revision path.
- [ ] **1.2** Header size is a literal, and a test asserts it equals the serialized length. This assertion alone catches the prototype's 17-vs-33 bug class permanently.
- [ ] **1.3** Endianness is explicit, not inherited from the host.
- [ ] **1.4** The vector file's header is page-sized so the matrix base is page-aligned.
- [ ] **1.5** Exactly one file owns the authoritative slot count, and it is the only header rewritten in normal operation. One commit point, not three.
- [ ] **1.5a** Only that header carries a CRC. Write-once headers do not need one — magic, version, and a file-length check already cover them. **§4, §14**
- [ ] **1.5b** Nothing cheaply derivable is stored — not capacity, not record count, not dead count. A stored copy is a second source of truth that can disagree with the first, and drift persists across launches where a derived value self-heals. **§4**
- [ ] **1.6** Document records are sized so none straddles a page, and each carries its own checksum plus a monotonic sequence number. A torn append is then bounded to one record — the dangerous shape is a tear that lands a real uuid and garbage after it.
- [ ] **1.6a** Ranges are stored as `[start, end)`, not start-plus-count. Validating untrusted bytes then needs two comparisons and no arithmetic; `start + count` can overflow, and in Swift that *traps* — turning a corrupt record into a crash during recovery. **§4**
- [ ] **1.6b** A live/deleted flag exists and is not inferred from an empty range. A live document can legitimately own zero slots. **§4**
- [ ] **1.7** The mapping is read-only, owned by you (not `Data(.mappedIfSafe)`, which silently falls back to a full read), refcounted, and never remapped in place.
- [ ] **1.8** Writes go to the file descriptor, not through the mapping.
- [ ] **1.9** Growth publishes a *new* mapping; the old one survives until its last reader releases it.
- [ ] **1.10** A golden byte-for-byte header fixture exists, so a later refactor cannot silently change the on-disk format.

## Phase 2 — The index. §5–§13

### Ordering and concurrency — no second chances

- [ ] **2.1** Every mutation is one synchronous, unyielded region. Not `async`, not an actor. **§1**
- [ ] **2.2** Sync cost is amortized by group commit, never by suspension. **§2, §7**
- [ ] **2.3** Payload is synced before the count is published. Cheap primitive on the hot path; expensive one only at compaction commit and clean shutdown. **§2**
- [ ] **2.4** A clean-shutdown bit exists, and an unclean open takes the conservative path instead of trusting the tail. **§2**

### Insert

- [ ] **2.5** The write routine *returns the range it wrote*, and the record is built from that return value. The `pieces.count` mistake is unrepresentable, not merely asserted against. **§7**
- [ ] **2.6** A document with zero embeddable pieces still gets a **live** record with an empty range. Skip it and reconcile queues it for re-index on every open, forever. **§4, §7**
- [ ] **2.7** Zero-norm and non-finite vectors are rejected at insert.
- [ ] **2.8** The map file grows before the vector file.

### Open

- [ ] **2.9** Records are validated individually, *then* folded last-valid-wins. Not the reverse. **§6**
- [ ] **2.10** Reconciliation runs in both directions against SQLite. **§6**
- [ ] **2.11** Stored dimensionality is checked against the live embedder.
- [ ] **2.12** Capacity is derived from file length, never stored. Differing file lengths resolve to the minimum and are re-grown before any write. **§4, §6**
- [ ] **2.12a** `slotCount` is clamped to the derived capacity on read. A torn header can read large, and an unclamped scan runs off the end of the mapping. **§6**
- [ ] **2.13** Orphaned generations are swept.

### Mutate

- [ ] **2.14** Update appends the new range *before* tombstoning the old one. **§9**
- [ ] **2.15** Delete tombstones a contiguous range and never touches the vector file. **§8**

### Search

- [ ] **2.16** The scan covers the live count, not the capacity. **§10**
- [ ] **2.17** Tombstones are skipped *during* selection, and the fetch is widened by the dead fraction. **§10**
- [ ] **2.18** Non-finite scores cannot enter the heap. **§10**
- [ ] **2.19** The tie-break rule is documented and separately tested.
- [ ] **2.20** The scan is tiled and parallel, using the modern BLAS interface.
- [ ] **2.21** In-document search is a contiguous sub-matrix scan. **§11**

### Maintenance

- [ ] **2.22** Compaction is two-phase: bulk work off-actor, replay and commit synchronous. **§12**
- [ ] **2.23** Only one compaction can run at a time.
- [ ] **2.24** Single-process access is enforced by a lock, not assumed.
- [ ] **2.25** Fault-injection points are built into the write path now, not retrofitted. **§13**
- [ ] **2.26** A debug-only validator implements the §14 invariants, and tests call it after every mutation.

## Phase 3 — Proving parity

- [ ] **3.1** Both backends are selectable and runnable on identical inputs.
- [ ] **3.2** Score comparison uses an absolute tolerance, not equality — different accumulation order moves the last bits.
- [ ] **3.3** Set equality is asserted only on fixtures whose score separation is itself asserted.
- [ ] **3.4** End-to-end identical ranked document lists over the full query suite. This is the assertion to actually trust.
- [ ] **3.5** A seeded fuzz test applies random create/update/delete sequences to both backends. This is what finds tombstone and renumbering bugs; point queries never will.
- [ ] **3.6** The benchmark reports *allocated* size, not logical — a pre-grown sparse file otherwise reads as a disk regression.
- [ ] **3.7** Bytes-written is measured, not modeled. The existing model assumes the behavior being deleted, so it would silently report ~0.
- [ ] **3.8** Dead-slot ratio and compaction count are reported per checkpoint, or a good intake number may just mean compaction never ran.

## Phase 4 — Crash matrix

- [ ] **4.1** Each fault point asserts: the count is the pre- or post-value and never in between; every surviving record is self-consistent; results are one whole state or the other, never a mixture; retry after recovery produces no duplicate.
- [ ] **4.2** A corruption matrix — truncation grid and header bit flips — proves open either succeeds self-consistently or throws typed. Never traps, never returns a garbage slot.
- [ ] **4.3** A real `SIGKILL`-a-child harness runs nightly.
- [ ] **4.4** The limit is written down in the test file header: true power loss is not reproducible in-process, so sync ordering is reasoned, not tested.

## Phase 5 — Migration

- [ ] **5.1** Absent new index plus present legacy index produces a typed "needs re-embed" — not a crash, and not a silently empty index.
- [ ] **5.2** The app's existing re-embed flow drives it. Build nothing new.
- [ ] **5.3** The legacy directory is renamed, not deleted, and removed only after a later clean open.
- [ ] **5.4** A dimension mismatch routes to the same path.

## Phase 6 — Swap

- [ ] **6.1** The default flips, revertible in one line.
- [ ] **6.2** FAISS removed from the package; all three `Package.resolved` files refreshed.
- [ ] **6.3** `removeDocument`'s piece-ID parameter dropped, and the SQLite fetch it forced deleted.
- [ ] **6.4** The acceptance gates in the plan file are met and the numbers recorded.

## Concepts to re-check yourself against

Not phase-specific. Losing any one of these quietly breaks something later.

1. **SQLite is truth; the index is a rebuildable cache.** `textContent` survives, so every recovery path can end in re-embed rather than data loss. This is why vectors are not duplicated. **F-6**
2. **Slot position is identity.** No IDs in the matrix. Translation applies only to the rows that survive selection.
3. **Piece rowids are never reused.** `AUTOINCREMENT` guarantees it, and that is what stops a leaked map entry from ever aliasing a future piece. A schema change could take it away.
4. **Per-document contiguity is load-bearing.** It makes delete one write instead of N lookups, and in-document search a sub-matrix instead of a gather. It survives only because you exclusively append. **F-12**
5. **Cost proportional to change, not to size.** The test for any new operation: does it write bytes proportional to what changed? If not, it is the 380 GiB bug in a new costume. **F-7**
6. **Quantization and approximate indexing both change what search returns**, so both need recall ground truth captured while exhaustive search is still cheap enough to be the reference. **F-8**

## The five silent failures

Each produces wrong answers with no error and no crash. Check these first when something feels off.

1. Slot count derived from `pieces.count` → one document's text served inside another document's result. **§7**
2. An `await` inside the append → two documents writing overlapping ranges, both passing validation. **§1**
3. Folding before validating → a document with a perfectly intact range vanishes at open. **§6**
4. Tombstones filtered after selection → a query returns nothing when results exist. **§10**
5. Scanning capacity instead of the live count → zero-filled slots score `0.0` and outrank every real negative-cosine match. **§10**
