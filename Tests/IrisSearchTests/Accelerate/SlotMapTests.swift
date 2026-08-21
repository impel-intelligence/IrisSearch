//
//  SlotMapTest.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//  Edited by Claude Opus 5 (Anthropic) on 8/17/26.
//

import Foundation
import Testing
@testable import IrisSearch

struct SlotMapTest {

    // MARK: - Helpers

    /// The file length a `map.bin` would have if it held exactly `slots` entries.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func fileLength(forSlots slots: Int) -> Int {
        SlotMap.Header.byteCount + (MemoryLayout<UInt64>.size * slots)
    }

    /// A whole `slot.bin` image: a valid header followed by room for the slots it declares.
    ///
    /// The decoder derives capacity from the buffer it is handed, so the buffer *is* the file. A
    /// bare header claiming N slots is not an under-specified fixture, it is a corrupt file, and
    /// the gate is supposed to reject it — see `testRejectsSlotCountLargerThanTheFileCanHold`.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func validHeaderBytes(
        slots: Int = 10,
        generation: UInt64 = 3
    ) -> (bytes: [UInt8], fileLength: Int) {
        let header = SlotMap.Header(slotCount: slots, generation: generation)
        var bytes = header.encoded()
        bytes.append(contentsOf: repeatElement(0, count: MemoryLayout<UInt64>.size * slots))
        return (bytes, fileLength(forSlots: slots))
    }

    // MARK: - Construction

    @Test func testCreateNew() async throws {
        let entries: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        let map = SlotMap(entries: entries, generation: 0)

        #expect(map.header.slotCount == entries.count, "Slots should be fully loaded")
    }

    @Test func testAppendEntries() async throws {
        let entries: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        let map = SlotMap(entries: [], generation: 0)

        map.append(ids: entries)

        #expect(map.header.slotCount == entries.count, "Slots should be fully loaded")
    }

    // MARK: - Format contract

    @Test func testHeaderByteSize() async throws {
        let header = SlotMap.Header(slotCount: 0, generation: 0)
        let data = header.encoded()
        #expect(data.count == SlotMap.Header.byteCount, "An empty map should only be as big as the header.")
    }

    @Test func testHeaderFieldsLandOnDeclaredOffsets() async throws {
        let (bytes, _) = Self.validHeaderBytes(slots: 10, generation: 3)

        #expect(Array(bytes[0..<4]) == Array("IMAP".utf8), "magic at offset 0")
        #expect(Array(bytes[4..<8]) == [1, 0, 0, 0], "version 1, little-endian u32 at offset 4")
        #expect(Array(bytes[8..<16]) == [10, 0, 0, 0, 0, 0, 0, 0], "slotCount 10, little-endian u64 at offset 8")
        #expect(Array(bytes[16..<24]) == [3, 0, 0, 0, 0, 0, 0, 0], "generation 3, little-endian u64 at offset 16")
    }

    @Test func testMultiByteFieldsAreLittleEndianOnDisk() async throws {
        // Built directly rather than through `validHeaderBytes`: this asserts the on-disk byte
        // order of the slotCount field and never decodes, so the value is chosen for its byte
        // pattern rather than for being a plausible count. Routing it through the helper would
        // try to allocate a buffer for 72 quadrillion slots.
        let bytes = SlotMap.Header(slotCount: 0x0102_0304_0506_0708, generation: 0).encoded()

        #expect(Array(bytes[8..<16]) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01],
                "On-disk byte order is the format contract; it must not silently follow host order.")
    }

    // MARK: - Round trip

    @Test func testHeaderRoundTrip() async throws {
        let slotCount: Int = 10
        let header = SlotMap.Header(slotCount: slotCount, generation: 3)
        // A header is only decodable inside a buffer big enough to hold what it declares.
        var data = header.encoded()
        data.append(contentsOf: repeatElement(0, count: MemoryLayout<UInt64>.size * slotCount))
        let decoded = try SlotMap.Header(bytes: data)

        #expect(header.slotCount == decoded.slotCount, "Slot counts should be the same.")
        #expect(header.generation == decoded.generation, "Generation should be the same.")
    }

    @Test func testReEncodingADecodedHeaderReproducesTheSameBytes() async throws {
        let (bytes, _) = Self.validHeaderBytes()
        let decoded = try SlotMap.Header(bytes: bytes)

        #expect(decoded.encoded() == Array(bytes.prefix(SlotMap.Header.byteCount)),
                "encode -> decode -> encode must be a fixed point, or a field is being dropped or widened.")
    }

    @Test func testEmptyHeaderRoundTrip() async throws {
        let header = SlotMap.Header(slotCount: 0, generation: 0)
        let decoded = try SlotMap.Header(bytes: header.encoded())

        #expect(decoded.slotCount == 0)
    }

    // MARK: - Validation gates

    @Test func testRejectsBufferShorterThanHeader() async throws {
        let short = [UInt8](repeating: 0, count: SlotMap.Header.byteCount - 1)

        #expect {
            _ = try SlotMap.Header(bytes: short)
        } throws: { error in
            guard case SlotMapError.truncatedFile = error else { return false }
            return true
        }
    }

    @Test func testRejectsForeignMagicWithoutClaimingCorruption() async throws {
        // The one error that must not lead to "discard and rebuild": the file was never ours,
        // and rebuilding over it destroys data belonging to something else.
        var (bytes, _) = Self.validHeaderBytes()
        bytes.replaceSubrange(0..<4, with: Array("SQLi".utf8))

        #expect {
            _ = try SlotMap.Header(bytes: bytes)
        } throws: { error in
            guard case SlotMapError.notASlotMap = error else { return false }
            return true
        }
    }

    @Test func testRejectsUnknownVersion() async throws {
        var (bytes, _) = Self.validHeaderBytes()
        bytes[4] = 99

        #expect {
            _ = try SlotMap.Header(bytes: bytes)
        } throws: { error in
            guard case SlotMapError.unsupportedVersion(let found, let supported) = error else { return false }
            return found == 99 && supported == SlotMap.Header.version
        }
    }

    @Test func testRejectsAnyFlippedBitInTheChecksummedRange() async throws {
        // Every byte the CRC claims to cover must actually be covered. Flipping each one in
        // turn is the only way to find a field accidentally left outside its range.
        let (original, _) = Self.validHeaderBytes()

        for index in 4..<28 {   // magic is skipped: it fails the earlier, more specific gate
            var corrupted = original
            corrupted[index] ^= 0xFF

            #expect {
                _ = try SlotMap.Header(bytes: corrupted)
            } throws: { error in
                switch error {
                case SlotMapError.checksumMismatch, SlotMapError.unsupportedVersion,
                     SlotMapError.slotCountExceedsFileSize:
                    return true
                default:
                    return false
                }
            }
        }
    }

    @Test func testRejectsSlotCountLargerThanTheFileCanHold() async throws {
        // A torn write leaves an intact header describing slots that were never written.
        // The CRC cannot catch this: the damage is past the range it covers.
        // A file with room for exactly 3 slots, whose header claims four billion.
        let header = SlotMap.Header(slotCount: 4_000_000_000, generation: 0)
        var bytes = header.encoded()
        bytes.append(contentsOf: repeatElement(0, count: MemoryLayout<UInt64>.size * 3))

        #expect {
            _ = try SlotMap.Header(bytes: bytes)
        } throws: { error in
            guard case SlotMapError.slotCountExceedsFileSize(let declared, let maximum) = error else { return false }
            return declared == 4_000_000_000 && maximum == 3
        }
    }

    @Test func testAcceptsSlotCountExactlyFillingTheFile() async throws {
        let header = SlotMap.Header(slotCount: 3, generation: 0)
        var bytes = header.encoded()
        bytes.append(contentsOf: repeatElement(0, count: MemoryLayout<UInt64>.size * 3))
        let decoded = try SlotMap.Header(bytes: bytes)

        #expect(decoded.slotCount == 3, "The bound is inclusive; an exactly-full file is valid, not an error.")
    }

    @Test func testDecodingArbitraryBytesNeverTraps() async throws {
        // File bytes are untrusted input. A trap is not an error: it aborts the process and no
        // `catch` can reach it, turning a corrupt cache into a launch-time crash loop.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let noise = (0..<SlotMap.Header.byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? SlotMap.Header(bytes: noise)
        }
    }

    // MARK: - Encoded body

    @Test func testEmptyByteSize() async throws {
        let map = SlotMap(entries: [], generation: 0)
        let data = map.encoded()
        #expect(data.count == SlotMap.Header.byteCount, "An empty map should only be as big as the header.")
    }

    @Test func testByteSize() async throws {
        let entries: [UInt64] = [0, 1, 2]
        let map = SlotMap(entries: entries, generation: 0)
        let data = map.encoded()
        #expect(data.count == map.byteCount, "An empty map should only be as big as the header.")
        #expect(data.count == Self.fileLength(forSlots: entries.count))
    }

    @Test func testEntriesAreWrittenAfterTheHeaderInOrder() async throws {
        let map = SlotMap(entries: [10, 20, 30], generation: 0)
        let bytes = map.encoded()
        let start = SlotMap.Header.byteCount

        #expect(Array(bytes[start..<(start + 8)]) == [10, 0, 0, 0, 0, 0, 0, 0], "slot 0")
        #expect(Array(bytes[(start + 8)..<(start + 16)]) == [20, 0, 0, 0, 0, 0, 0, 0], "slot 1")
        #expect(Array(bytes[(start + 16)..<(start + 24)]) == [30, 0, 0, 0, 0, 0, 0, 0], "slot 2")
    }

    @Test func testHeaderSlotCountMatchesEntriesAfterEveryMutation() async throws {
        // The stored-vs-derived drift behind the cachedPieceCount bug: any write path that
        // forgets the header writes a file whose body it cannot describe.
        let map = SlotMap(entries: [1, 2, 3], generation: 0)
        #expect(map.header.slotCount == map.count)

        map.append(ids: [4, 5, 6, 7])
        #expect(map.header.slotCount == map.count)

        map.tombstone(range: 0..<2)
        #expect(map.header.slotCount == map.count, "Tombstoning does not remove slots.")

        let encoded = map.encoded()
        let decoded = try SlotMap.Header(bytes: encoded)
        #expect(decoded.slotCount == map.count,
                "The header on disk must describe the entries actually written after it.")
    }

    // MARK: - Append

    @Test func testAppendReturnsTheRangeItWrote() async throws {
        let map = SlotMap(entries: [], generation: 0)

        let first = map.append(ids: [1, 2, 3])
        #expect(first == 0..<3)

        let second = map.append(ids: [4, 5])
        #expect(second == 3..<5, "Ranges are half-open and contiguous; a gap or overlap corrupts slot identity.")

        #expect(map[first.lowerBound] == 1)
        #expect(map[second.upperBound - 1] == 5)
    }

    @Test func testAppendOfNothingChangesNothing() async throws {
        let map = SlotMap(entries: [1, 2, 3], generation: 0)
        let range = map.append(ids: [])

        #expect(range.isEmpty)
        #expect(map.count == 3)
    }

    // MARK: - Tombstones

    @Test func testTombstoneMarksTheFirstDocumentsRange() async throws {
        // An earlier bounds guard was off by one at both ends, so the very first and very last
        // document silently failed to tombstone.
        let map = SlotMap(entries: [1, 2, 3, 4, 5], generation: 0)
        map.tombstone(range: 0..<3)

        #expect(map.deadCount == 3)
        #expect(!map.isLive(0))
        #expect(!map.isLive(2))
        #expect(map.isLive(3))
    }

    @Test func testTombstoneMarksTheLastDocumentsRange() async throws {
        let map = SlotMap(entries: [1, 2, 3, 4, 5], generation: 0)
        map.tombstone(range: 2..<5)

        #expect(map.deadCount == 3)
        #expect(map.isLive(1))
        #expect(!map.isLive(4), "upperBound is exclusive, so the final slot must still be marked.")
    }

    @Test func testTombstoningTwiceDoesNotDoubleCount() async throws {
        let map = SlotMap(entries: [1, 2, 3, 4, 5], generation: 0)
        map.tombstone(range: 1..<4)
        map.tombstone(range: 1..<4)

        #expect(map.deadCount == 3, "deadCount counts tombstoned slots, not tombstone operations.")
        #expect(map.deadFraction == 0.6)
    }

    @Test func testOverlappingTombstonesCountEachSlotOnce() async throws {
        let map = SlotMap(entries: [1, 2, 3, 4, 5], generation: 0)
        map.tombstone(range: 0..<3)
        map.tombstone(range: 2..<5)

        #expect(map.deadCount == 5)
        #expect(map.deadFraction == 1.0)
    }

    @Test func testDeadCountIsRecoveredFromEntriesOnLoad() async throws {
        let map = SlotMap(entries: [1, SlotMap.tombstoneValue, 3, SlotMap.tombstoneValue], generation: 0)

        #expect(map.deadCount == 2, "deadCount is derived, not stored, so it must be rebuilt by scanning.")
        #expect(map.deadFraction == 0.5)
    }

    @Test func testDeadFractionOfAnEmptyMapIsZeroNotNaN() async throws {
        let map = SlotMap(entries: [], generation: 0)

        #expect(map.deadFraction == 0)
        #expect(!map.deadFraction.isNaN, "NaN traps downstream: Int(nan) aborts in the over-fetch widener.")
    }

    @Test func testTombstoneValueIsNotAReachablePieceID() async throws {
        #expect(SlotMap.tombstoneValue == UInt64.max,
                "The sentinel must sit outside the range SQLite can assign, or a live row reads as dead.")
    }

    // MARK: - Whole-map round trip

    /// Encodes a map and decodes it back, passing the file length the encoding actually produced.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func roundTrip(_ map: SlotMap) throws -> SlotMap {
        let bytes = map.encoded()
        return try SlotMap(bytes: bytes)
    }

    @Test func testEmptyMapRoundTrip() async throws {
        let decoded = try Self.roundTrip(SlotMap(entries: [], generation: 0))

        #expect(decoded.count == 0)
        #expect(decoded.entries.isEmpty)
        #expect(decoded.header.slotCount == 0)
        #expect(decoded.deadCount == 0)
    }

    @Test func testEntriesSurviveRoundTripInOrder() async throws {
        let entries: [UInt64] = [10, 20, 30, 40, 50]
        let decoded = try Self.roundTrip(SlotMap(entries: entries, generation: 0))

        #expect(decoded.entries == entries, "Order is identity here: slot N must still hold the piece it held.")
        #expect(decoded.count == entries.count)
        #expect(decoded.header.slotCount == entries.count)
    }

    @Test func testRoundTripPreservesTheFullUInt64Range() async throws {
        // A value that differs in every byte catches a decoder that truncates to 32 bits or
        // reverses byte order, both of which survive small test values unnoticed.
        let entries: [UInt64] = [0, 1, UInt64.max - 1, 0x0102_0304_0506_0708, UInt64.max]
        let decoded = try Self.roundTrip(SlotMap(entries: entries, generation: 0))

        #expect(decoded.entries == entries)
    }

    @Test func testRoundTripIsAFixedPointOnBytes() async throws {
        // encode -> decode -> encode must reproduce the original bytes exactly. This is the
        // single assertion that catches a dropped field, a widened field, or a shifted offset.
        let map = SlotMap(entries: [1, 2, 3, SlotMap.tombstoneValue, 5], generation: 0)
        let first = map.encoded()
        let second = try SlotMap(bytes: first).encoded()

        #expect(second == first)
    }

    @Test func testDecodePreservesHeaderState() async throws {
        // Built header-first because `header` is private(set) and `SlotMap(entries:)` always
        // starts at generation 0 with no flags -- there is currently no way to reach any other
        // header state through the type's own API, which is itself worth noticing.
        var bytes = SlotMap.Header(slotCount: 3, generation: 42).encoded()
        [UInt64(1), 2, 3].map { $0.littleEndian }.withUnsafeBytes { bytes.append(contentsOf: $0) }

        let decoded = try SlotMap(bytes: bytes)

        #expect(decoded.header.generation == 42, "generation drives the compaction directory swap.")
        #expect(decoded.entries == [1, 2, 3])
    }

    @Test func testTombstonesSurviveRoundTripAndDeadCountIsRescanned() async throws {
        // deadCount is derived, never written. After a load it must come back from the entries
        // themselves, or a compaction trigger reads a stale fraction.
        let map = SlotMap(entries: [1, 2, 3, 4, 5], generation: 0)
        map.tombstone(range: 1..<3)

        let decoded = try Self.roundTrip(map)

        #expect(decoded.entries == [1, SlotMap.tombstoneValue, SlotMap.tombstoneValue, 4, 5])
        #expect(decoded.deadCount == 2)
        #expect(decoded.deadFraction == 0.4)
        #expect(decoded.isLive(0))
        #expect(!decoded.isLive(1))
    }

    @Test func testRoundTripAfterAppend() async throws {
        let map = SlotMap(entries: [1, 2, 3], generation: 0)
        map.append(ids: [4, 5, 6, 7])

        let decoded = try Self.roundTrip(map)

        #expect(decoded.entries == [1, 2, 3, 4, 5, 6, 7])
        #expect(decoded.header.slotCount == 7, "The header must describe the entries appended after it.")
    }

    @Test func testDecodedMapCanBeAppendedToAndReEncoded() async throws {
        // A load is not read-only: the next write cycle appends to whatever came back.
        let original = SlotMap(entries: [1, 2, 3], generation: 0)
        let decoded = try Self.roundTrip(original)

        let range = decoded.append(ids: [4, 5])
        #expect(range == 3..<5, "Slot numbering must continue from the loaded count, not restart.")

        let reloaded = try Self.roundTrip(decoded)
        #expect(reloaded.entries == [1, 2, 3, 4, 5])
        #expect(reloaded.byteCount == Self.fileLength(forSlots: 5))
    }

    @Test func testLargeMapRoundTrip() async throws {
        // Bulk decode paths differ from the small case: this catches a stride error or a
        // truncated final chunk that a five-element map never reaches.
        let entries = (0..<100_000).map { UInt64($0) &* 2_654_435_761 }
        let decoded = try Self.roundTrip(SlotMap(entries: entries, generation: 0))

        #expect(decoded.count == entries.count)
        #expect(decoded.entries == entries)
    }

    @Test func testDecodeReadsOnlyTheSlotsTheHeaderCommitted() async throws {
        // slotCount is the commit point. Bytes past it are an append that never committed --
        // a process that died between writing slots and updating the header. Decoding them
        // resurrects records SQLite has no rows for.
        let map = SlotMap(entries: [1, 2, 3], generation: 0)
        var bytes = map.encoded()

        // Simulate the torn append: two slots written, header never updated.
        [UInt64(4), UInt64(5)].map { $0.littleEndian }.withUnsafeBytes { bytes.append(contentsOf: $0) }

        let decoded = try SlotMap(bytes: bytes)

        #expect(decoded.count == 3, "Uncommitted trailing slots must be ignored, not adopted.")
        #expect(decoded.entries == [1, 2, 3])
    }
    
    @Test func testDecodeProducesEmptyEntries() async throws {
        let map = SlotMap(entries: [], generation: 0)
        var bytes = map.encoded()

        let decoded = try SlotMap(bytes: bytes)

        #expect(decoded.count == 0, "Uncommitted trailing slots must be ignored, not adopted.")
        #expect(decoded.entries == [])
    }


    @Test func testDecodeRejectsFewerSlotBytesThanTheHeaderClaims() async throws {
        // The mirror case: the header committed slots whose bytes were lost to truncation.
        // Reading them would run past the buffer, which on a mapped file is SIGBUS.
        let map = SlotMap(entries: [1, 2, 3], generation: 0)
        let bytes = Array(map.encoded().dropLast(8))

        #expect {
            _ = try SlotMap(bytes: bytes)
        } throws: { error in
            switch error {
            case SlotMapError.truncatedFile, SlotMapError.slotCountExceedsFileSize:
                return true
            default:
                return false
            }
        }
    }

    @Test func testDecodePropagatesHeaderErrors() async throws {
        var bytes = SlotMap(entries: [1, 2, 3], generation: 0).encoded()
        bytes.replaceSubrange(0..<4, with: Array("SQLi".utf8))

        #expect {
            _ = try SlotMap(bytes: bytes)
        } throws: { error in
            guard case SlotMapError.notASlotMap = error else { return false }
            return true
        }
    }

    @Test func testDecodesEntriesAsLittleEndianRegardlessOfHost() async throws {
        // Built by hand rather than by the encoder, so a decoder that agrees with a buggy
        // encoder cannot make this pass.
        var bytes = SlotMap.Header(slotCount: 2, generation: 0).encoded()
        bytes.append(contentsOf: [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let decoded = try SlotMap(bytes: bytes)

        #expect(decoded.entries == [0x0102_0304_0506_0708, 1])
    }

    @Test func testDecodingArbitraryTrailingBytesNeverTraps() async throws {
        // Entry bytes are as untrusted as header bytes. A trap here aborts the process and no
        // catch can reach it.
        var generator = SystemRandomNumberGenerator()
        let header = SlotMap.Header(slotCount: 4, generation: 0).encoded()

        for _ in 0..<200 {
            var bytes = header
            bytes.append(contentsOf: (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? SlotMap(bytes: bytes)
        }
    }
}
