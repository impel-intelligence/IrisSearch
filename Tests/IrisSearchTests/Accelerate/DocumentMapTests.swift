//
//  DocumentMapTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//  Edited by Claude Opus 5 (Anthropic) on 8/17/26.
//

import Foundation
import Testing
import CryptoSwift
@testable import IrisSearch

private typealias Record = DocumentMap.Record
private typealias Header = DocumentMap.Header

private let uuidA = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
private let uuidB = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")!

struct DocumentMapTests {

    // MARK: - Record format contract

    @Test func testRecordEncodesToExactlyByteCount() async throws {
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])

        #expect(record.encoded().count == Record.byteCount,
                "A record must be exactly 64 B so none straddles a 4096 B page and a torn append damages only one.")
    }

    @Test func testRecordFieldsLandOnDeclaredOffsets() async throws {
        let record = Record(uuid: uuidA, documentID: 7, slotStart: 3, slotEnd: 9, sequence: 5, flags: [.live])
        let bytes = record.encoded()

        #expect(Array(bytes[16..<24]) == [7, 0, 0, 0, 0, 0, 0, 0], "documentID u64 at 16")
        #expect(Array(bytes[24..<32]) == [3, 0, 0, 0, 0, 0, 0, 0], "startSlot u64 at 24")
        #expect(Array(bytes[32..<40]) == [9, 0, 0, 0, 0, 0, 0, 0], "endSlot u64 at 32")
        #expect(Array(bytes[40..<48]) == [5, 0, 0, 0, 0, 0, 0, 0], "sequence u64 at 40")
        #expect(bytes[48] == 1, "live flag at 48")
    }

    @Test func testUUIDIsStoredVerbatimNotByteSwapped() async throws {
        // A UUID is an ordered byte string, not an integer. Byte-swapping it yields a different
        // UUID that round-trips cleanly through our own code and then fails to match SQLite.
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let bytes = record.encoded()

        #expect(Array(bytes[0..<16]) == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                         0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
                "UUID bytes must appear on disk in display order, with no endian conversion.")
    }

    @Test func testRecordRoundTrip() async throws {
        let original = Record(uuid: uuidB, documentID: 99, slotStart: 12, slotEnd: 40, sequence: 7, flags: [.live])
        let bytes = original.encoded()

        let decoded = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 1_000)

        #expect(decoded.uuid == original.uuid)
        #expect(decoded.documentID == original.documentID)
        #expect(decoded.startSlot == original.startSlot)
        #expect(decoded.endSlot == original.endSlot)
        #expect(decoded.sequence == original.sequence)
        #expect(decoded.flags == original.flags)
        #expect(decoded.isLive)
    }

    @Test func testDeadRecordRoundTripsAsDead() async throws {
        // If flags are dropped on the way out, every record decodes as dead and the whole map
        // loads empty -- and every other test still passes.
        let tombstone = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: .empty)
        let bytes = tombstone.encoded()

        let decoded = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 1_000)

        #expect(!decoded.isLive)
        #expect(bytes[48] == 0, "no live bit set")
    }

    @Test func testRecordDecodesAtANonZeroBase() async throws {
        // Records after the first are read at base = 64 + n*64. An offset the decoder ignores
        // makes every record after the first decode as a copy of the first.
        let first = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let second = Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6, sequence: 2, flags: [.live])

        var bytes = Header(generation: 0).encoded()
        first.encode(into: &bytes)
        second.encode(into: &bytes)

        let decoded = try Record(bytes: bytes, at: 128, fileLength: bytes.count, maximumSlotCount: 1_000)

        #expect(decoded.uuid == uuidB)
        #expect(decoded.documentID == 2)
    }

    // MARK: - Record validation

    @Test func testRecordRejectsAnyFlippedBitInTheChecksummedRange() async throws {
        // Every byte the CRC claims to cover must actually be covered. Flipping each one in turn
        // is the only way to find a field accidentally left outside its range.
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 1, slotEnd: 2, sequence: 3, flags: [.live])
        let original = record.encoded()

        for index in 0..<52 {
            var corrupted = original
            corrupted[index] ^= 0xFF

            #expect {
                _ = try Record(bytes: corrupted, at: 0, fileLength: corrupted.count, maximumSlotCount: 1_000)
            } throws: { error in
                switch error {
                case DocumentMapError.checksumMismatch,
                     DocumentMapError.recordStartAfterRecordEnd,
                     DocumentMapError.recordPastMaximumSlots:
                    return true
                default:
                    return false
                }
            }
        }
    }

    @Test func testRecordRejectsInvertedRange() async throws {
        // Written by hand so the range is inverted but the checksum still matches -- otherwise
        // this would fail at the CRC gate and never reach the ordering check.
        var bytes = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 0, sequence: 1, flags: [.live]).encoded()
        bytes.store(UInt64(9), at: Record.Offset.startSlot)
        bytes.store(UInt64(4), at: Record.Offset.endSlot)
        bytes.store(Checksum.crc32(Array(bytes[0..<52])), at: Record.Offset.checksum)

        #expect {
            _ = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 1_000)
        } throws: { error in
            guard case DocumentMapError.recordStartAfterRecordEnd = error else { return false }
            return true
        }
    }

    @Test func testRecordRejectsRangePastCommittedSlots() async throws {
        // A record naming slots map.bin never committed. Reading them on a mapped region is
        // SIGBUS, which no catch can reach -- so it has to be refused here.
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 50, sequence: 1, flags: [.live])
        let bytes = record.encoded()

        #expect {
            _ = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 10)
        } throws: { error in
            guard case DocumentMapError.recordPastMaximumSlots = error else { return false }
            return true
        }
    }

    @Test func testRecordAcceptsRangeEndingExactlyAtCommittedSlots() async throws {
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 5, slotEnd: 10, sequence: 1, flags: [.live])
        let bytes = record.encoded()

        let decoded = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 10)

        #expect(decoded.endSlot == 10, "endSlot is exclusive, so == committed count is valid, not an overflow.")
    }

    @Test func testEmptyRangeIsValidAndLive() async throws {
        // An image-only document embeds nothing and legitimately owns zero slots. If an empty
        // range were read as deletion, reconcile would re-index it on every open forever.
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 4, slotEnd: 4, sequence: 1, flags: [.live])
        let bytes = record.encoded()

        let decoded = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 10)

        #expect(decoded.isLive)
        #expect(decoded.startSlot == decoded.endSlot)
    }

    @Test func testRecordRejectsBufferTooShortForItsBase() async throws {
        let record = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let bytes = Array(record.encoded().dropLast(8))

        #expect {
            _ = try Record(bytes: bytes, at: 0, fileLength: bytes.count, maximumSlotCount: 1_000)
        } throws: { error in
            guard case DocumentMapError.truncatedFile = error else { return false }
            return true
        }
    }

    // MARK: - Header

    @Test func testHeaderEncodesToExactlyByteCount() async throws {
        #expect(Header(generation: 0).encoded().count == Header.byteCount)
    }

    @Test func testHeaderRoundTrip() async throws {
        let bytes = Header(generation: 12).encoded()

        let decoded = try Header(bytes: bytes, fileLength: bytes.count)

        #expect(decoded.generation == 12)
        #expect(Array(bytes[0..<4]) == Array("IDOC".utf8), "magic at offset 0")
    }

    @Test func testHeaderRejectsForeignMagic() async throws {
        // Not "our file, damaged" but "not our file" -- the one error that must never lead to
        // discard-and-rebuild, because rebuilding would destroy someone else's data.
        var bytes = Header(generation: 0).encoded()
        bytes.replaceSubrange(0..<4, with: Array("IMAP".utf8))

        #expect {
            _ = try Header(bytes: bytes, fileLength: bytes.count)
        } throws: { error in
            guard case DocumentMapError.notADocumentMap = error else { return false }
            return true
        }
    }

    @Test func testHeaderRejectsUnknownVersion() async throws {
        var bytes = Header(generation: 0).encoded()
        bytes[4] = 99

        #expect {
            _ = try Header(bytes: bytes, fileLength: bytes.count)
        } throws: { error in
            guard case DocumentMapError.unsupportedVersion = error else { return false }
            return true
        }
    }

    // MARK: - Loading the log

    @Test func testEmptyFileLoadsAsEmptyMap() async throws {
        let bytes = Header(generation: 0).encoded()

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.count == 0)
        #expect(map.ranges.isEmpty)
        #expect(map.nextSequence == 0)
    }

    @Test func testSingleRecordLoads() async throws {
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 7, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.count == 1)
        #expect(map.ranges[uuidA]?.id == 7)
        #expect(map.ranges[uuidA]?.startSlot == 0)
        #expect(map.ranges[uuidA]?.endSlot == 3)
    }

    @Test func testEveryRecordInTheFileIsRead() async throws {
        // A stride bound computed as a count rather than an end offset reads only the first
        // record or none at all, and an empty map looks exactly like a fresh index.
        var bytes = Header(generation: 0).encoded()
        for index in 0..<10 {
            let slot = UInt64(index)
            Record(uuid: UUID(), documentID: slot, slotStart: slot, slotEnd: slot + 1,
                   sequence: slot + 1, flags: [.live])
                .encode(into: &bytes)
        }

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.count == 10, "All ten records must be folded, not just the ones before an early stride bound.")
    }

    @Test func testLastSequenceWinsForTheSameUUID() async throws {
        let created = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let updated = Record(uuid: uuidA, documentID: 1, slotStart: 3, slotEnd: 8, sequence: 2, flags: [.live])

        var bytes = Header(generation: 0).encoded()
        created.encode(into: &bytes)
        updated.encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.count == 1)
        #expect(map.ranges[uuidA]?.startSlot == 3, "The newer record must win.")
        #expect(map.ranges[uuidA]?.endSlot == 8)
    }

    @Test func testFoldUsesSequenceNotFileOrder() async throws {
        // Compaction rewrites records in dictionary order, so byte position is not age.
        let newer = Record(uuid: uuidA, documentID: 1, slotStart: 9, slotEnd: 12, sequence: 5, flags: [.live])
        let older = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 2, flags: [.live])

        var bytes = Header(generation: 0).encoded()
        newer.encode(into: &bytes)      // written first, but has the higher sequence
        older.encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.ranges[uuidA]?.startSlot == 9, "Ordering must come from `sequence`, not byte position.")
    }

    @Test func testDeletionRemovesAnEarlierLiveRecord() async throws {
        // Deleting appends a tombstone; it cannot rewrite the file. If the fold skips non-live
        // records instead of applying them, a deleted document survives its own deletion.
        let createdA = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let createdB = Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6, sequence: 2, flags: [.live])
        let deletedA = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 3, flags: .empty)

        var bytes = Header(generation: 0).encoded()
        createdA.encode(into: &bytes)
        createdB.encode(into: &bytes)
        deletedA.encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.ranges[uuidA] == nil, "A tombstone must remove the entry, not be skipped.")
        #expect(map.ranges[uuidB] != nil)
        #expect(map.count == 1)
    }

    @Test func testDocumentCanBeResurrectedAfterDeletion() async throws {
        let created = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
        let deleted = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 2, flags: .empty)
        let recreated = Record(uuid: uuidA, documentID: 1, slotStart: 6, slotEnd: 9, sequence: 3, flags: [.live])

        var bytes = Header(generation: 0).encoded()
        created.encode(into: &bytes)
        deleted.encode(into: &bytes)
        recreated.encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.ranges[uuidA]?.startSlot == 6)
    }

    @Test func testNextSequenceIsOnePastTheHighestSeen() async throws {
        // Reusing a sequence makes "last write wins" a coin flip. The highest must be counted
        // even when it belongs to a tombstone.
        let created = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 4, flags: [.live])
        let deleted = Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 9, flags: .empty)

        var bytes = Header(generation: 0).encoded()
        created.encode(into: &bytes)
        deleted.encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.nextSequence == 10)
    }

    @Test func testInvalidRecordIsSkippedWithoutFailingTheLoad() async throws {
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6, sequence: 2, flags: [.live])
            .encode(into: &bytes)

        bytes[128 + Record.Offset.documentID] ^= 0xFF   // tear the second record

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.ranges[uuidA] != nil, "A torn record must not take the whole load down with it.")
        #expect(map.ranges[uuidB] == nil)
    }

    @Test func testInvalidRecordDoesNotShadowAGoodEarlierOne() async throws {
        // Validate each record independently, THEN fold. Folding first lets an interrupted
        // update shadow the perfectly good previous range and the document disappears entirely.
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidA, documentID: 1, slotStart: 3, slotEnd: 8, sequence: 2, flags: [.live])
            .encode(into: &bytes)

        bytes[128 + Record.Offset.startSlot] ^= 0xFF   // tear the update

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.ranges[uuidA]?.startSlot == 0,
                "The document keeps its last good range rather than vanishing.")
    }

    @Test func testPartialTrailingRecordIsIgnored() async throws {
        // A torn append leaves a fragment. The record count derives from the file length, so
        // truncating division must drop it rather than decoding past the end.
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 30))

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.count == 1)
        #expect(map.ranges[uuidA] != nil)
    }

    @Test func testLoadingArbitraryBytesNeverTraps() async throws {
        // Record bytes are as untrusted as header bytes. A trap here aborts the process and no
        // catch can reach it.
        var generator = SystemRandomNumberGenerator()

        for _ in 0..<200 {
            var bytes = Header(generation: 0).encoded()
            bytes.append(contentsOf: (0..<128).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)
        }
    }

    // MARK: - apply

    @Test func testApplyAddsALiveRecord() async throws {
        let map = DocumentMap()

        map.apply(record: Record(uuid: uuidA, documentID: 3, slotStart: 0, slotEnd: 4,
                                 sequence: 1, flags: [.live]))

        #expect(map.ranges[uuidA]?.id == 3)
        #expect(map.nextSequence == 2, "nextSequence is one past the record just applied.")
    }

    @Test func testApplyOfATombstoneRemovesTheEntry() async throws {
        let map = DocumentMap()

        map.apply(record: Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3,
                                 sequence: 1, flags: [.live]))
        map.apply(record: Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3,
                                 sequence: 2, flags: .empty))

        #expect(map.ranges[uuidA] == nil)
        #expect(map.count == 0)
    }

    @Test func testApplyNeverMovesNextSequenceBackwards() async throws {
        let map = DocumentMap()

        map.apply(record: Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3,
                                 sequence: 10, flags: [.live]))
        map.apply(record: Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6,
                                 sequence: 3, flags: [.live]))

        #expect(map.nextSequence == 11, "An out-of-order record must not lower the counter into reuse.")
    }

    // MARK: - Encoding the whole map

    @Test func testEncodeEmitsHeaderPlusOneRecordPerLiveDocument() async throws {
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6, sequence: 2, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 3, flags: .empty)
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)
        let encoded = map.encoded()

        #expect(encoded.count == Header.byteCount + Record.byteCount,
                "Encoding compacts: three log records, one live document, one record out.")
        #expect(encoded.count == map.byteCount, "byteCount must describe what encode actually produces.")
    }

    @Test func testEncodeIsIdempotent() async throws {
        // encode() must be a pure function of the map. If it advances state as it writes, the
        // same map serialises differently each time and no round trip can be asserted.
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)

        #expect(map.encoded() == map.encoded())
    }

    @Test func testEncodedMapReloadsWithTheSameRanges() async throws {
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 9, sequence: 2, flags: [.live])
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)
        let rewritten = map.encoded()
        let reloaded = try DocumentMap(bytes: rewritten, fileSize: rewritten.count, maximumSlotCount: 1_000)

        #expect(reloaded.count == 2)
        #expect(reloaded.ranges[uuidA]?.startSlot == 0)
        #expect(reloaded.ranges[uuidA]?.endSlot == 3)
        #expect(reloaded.ranges[uuidB]?.id == 2)
        #expect(reloaded.ranges[uuidB]?.endSlot == 9)
    }

    @Test func testEncodePreservesGeneration() async throws {
        var bytes = Header(generation: 17).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)
        let rewritten = map.encoded()
        let reloaded = try DocumentMap(bytes: rewritten, fileSize: rewritten.count, maximumSlotCount: 1_000)

        #expect(reloaded.header.generation == 17)
    }

    @Test func testEncodedRecordsAreAllLive() async throws {
        // Compaction drops history, so every record it emits describes a living document.
        var bytes = Header(generation: 0).encoded()
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 1, flags: [.live])
            .encode(into: &bytes)
        Record(uuid: uuidA, documentID: 1, slotStart: 0, slotEnd: 3, sequence: 2, flags: .empty)
            .encode(into: &bytes)
        Record(uuid: uuidB, documentID: 2, slotStart: 3, slotEnd: 6, sequence: 3, flags: [.live])
            .encode(into: &bytes)

        let map = try DocumentMap(bytes: bytes, fileSize: bytes.count, maximumSlotCount: 1_000)
        let encoded = map.encoded()
        let recordCount = (encoded.count - Header.byteCount) / Record.byteCount

        #expect(recordCount == 1)
        for index in 0..<recordCount {
            let base = Header.byteCount + index * Record.byteCount
            #expect(encoded[base + Record.Offset.flags] == 1)
        }
    }
}
