//
//  CompactionPlanTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/19/26.
//

import Foundation
import Testing
@testable import IrisSearch
@testable import IrisCommon

struct CompactionPlanTests {
    @Test("Compaction plan keeps all ranges since documentRanges is always only live documents.")
    func testCompactionPlanKeepsAllRanges() async throws {
        let docOneUUID = UUID()
        let docTwoUUID = UUID()
        
        let ranges: [UUID: DocumentLog.DocumentRange] = [
            docOneUUID: DocumentLog.DocumentRange(id: 0, startSlot: 0, endSlot: 1),
            docTwoUUID: DocumentLog.DocumentRange(id: 1, startSlot: 1, endSlot: 5),
        ]
        
        let plan = CompactionPlan(documentRanges: ranges)
        
        try #require(plan.moves.count == 2)
        
        #expect(plan.moves[0].uuid == docOneUUID)
        #expect(plan.moves[0].documentID == 0)
        #expect(plan.moves[0].sourceRange == 0..<1)
        #expect(plan.moves[0].newRange == 0..<1)
        
        #expect(plan.moves[1].uuid == docTwoUUID)
        #expect(plan.moves[1].documentID == 1)
        #expect(plan.moves[1].sourceRange == 1..<5)
        #expect(plan.moves[1].newRange == 1..<5)
    }
    
    @Test("Compaction plan fills holes.")
    func testCompactionPlanFillsHole() async throws {
        let docOneUUID = UUID()
        let docTwoUUID = UUID()
        
        let ranges: [UUID: DocumentLog.DocumentRange] = [
            docOneUUID: DocumentLog.DocumentRange(id: 0, startSlot: 0, endSlot: 1),
            docTwoUUID: DocumentLog.DocumentRange(id: 1, startSlot: 4, endSlot: 5),
        ]
        
        let plan = CompactionPlan(documentRanges: ranges)
        
        try #require(plan.moves.count == 2)
        
        #expect(plan.moves[0].uuid == docOneUUID)
        #expect(plan.moves[0].documentID == 0)
        #expect(plan.moves[0].sourceRange == 0..<1)
        #expect(plan.moves[0].newRange == 0..<1)
        
        #expect(plan.moves[1].uuid == docTwoUUID)
        #expect(plan.moves[1].documentID == 1)
        #expect(plan.moves[1].sourceRange == 4..<5)
        #expect(plan.moves[1].newRange == 1..<2)
    }

    @Test("Compaction plan fills holes.")
    func testCompactionPlanKeepsZeroLengthRange() async throws {
        let docOneUUID = UUID()
        
        let ranges: [UUID: DocumentLog.DocumentRange] = [
            docOneUUID: DocumentLog.DocumentRange(id: 0, startSlot: 0, endSlot: 0),
        ]
        
        let plan = CompactionPlan(documentRanges: ranges)
        
        try #require(plan.moves.count == 1)
        
        #expect(plan.moves[0].uuid == docOneUUID)
        #expect(plan.moves[0].documentID == 0)
        #expect(plan.moves[0].sourceRange == 0..<0)
        #expect(plan.moves[0].newRange == 0..<0)
    }

    @Test("Slot count is the sum of every live range's length.")
    func testCompactionPlanSlotCount() async throws {
        let ranges: [UUID: DocumentLog.DocumentRange] = [
            UUID(): DocumentLog.DocumentRange(id: 0, startSlot: 0, endSlot: 3),
            UUID(): DocumentLog.DocumentRange(id: 1, startSlot: 10, endSlot: 14),
            UUID(): DocumentLog.DocumentRange(id: 2, startSlot: 20, endSlot: 21),
        ]

        let plan = CompactionPlan(documentRanges: ranges)

        #expect(plan.slotCount == 8, "3 + 4 + 1, not the 21 slots the old file spans.")
    }

    @Test("An empty document set produces an empty plan.")
    func testCompactionPlanOfAnEmptyIndex() async throws {
        let plan = CompactionPlan(documentRanges: [:])

        #expect(plan.moves.isEmpty)
        #expect(plan.slotCount == 0)
    }

    @Test("Destination ranges abut with no gaps, whatever the source spacing.")
    func testCompactionPlanProducesContiguousDestinations() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        for index in 0..<20 {
            // Sources are deliberately spread out, as they would be after many deletions.
            let start = index * 7
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index),
                                                       startSlot: start,
                                                       endSlot: start + (index % 3) + 1)
        }

        let plan = CompactionPlan(documentRanges: ranges)

        try #require(plan.moves.count == 20)

        var expectedStart = 0
        for move in plan.moves {
            #expect(move.newRange.lowerBound == expectedStart,
                    "a gap here would leave an unowned slot in the compacted file")
            #expect(move.newRange.count == move.sourceRange.count,
                    "a move must not change how many slots a document owns")
            expectedStart = move.newRange.upperBound
        }
        #expect(expectedStart == plan.slotCount)
    }

    @Test("Moves are ordered by source, so the rewrite is one forward pass over the old file.")
    func testCompactionPlanOrdersMovesBySource() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        for index in 0..<32 {
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index),
                                                       startSlot: index * 2,
                                                       endSlot: index * 2 + 1)
        }

        let plan = CompactionPlan(documentRanges: ranges)
        let starts = plan.moves.map(\.sourceRange.lowerBound)

        #expect(starts == starts.sorted(),
                "Dictionary iteration order is unspecified; without the sort this would scatter reads.")
    }

    @Test("No destination ever runs ahead of its source, so a forward copy cannot overwrite unread bytes.")
    func testCompactionPlanNeverMovesASlotForward() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        for index in 0..<10 {
            let start = index * 5
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index),
                                                       startSlot: start,
                                                       endSlot: start + 2)
        }

        let plan = CompactionPlan(documentRanges: ranges)

        for move in plan.moves {
            #expect(move.newRange.lowerBound <= move.sourceRange.lowerBound,
                    "\(move.newRange) starts after \(move.sourceRange) — compaction only removes slots")
        }
    }

    @Test("A zero-length range does not advance the cursor.")
    func testCompactionPlanZeroLengthRangeDoesNotConsumeASlot() async throws {
        let imageOnlyUUID = UUID()
        let textUUID = UUID()

        let ranges: [UUID: DocumentLog.DocumentRange] = [
            imageOnlyUUID: DocumentLog.DocumentRange(id: 0, startSlot: 4, endSlot: 4),
            textUUID: DocumentLog.DocumentRange(id: 1, startSlot: 8, endSlot: 11),
        ]

        let plan = CompactionPlan(documentRanges: ranges)

        try #require(plan.moves.count == 2)

        #expect(plan.moves[0].uuid == imageOnlyUUID)
        #expect(plan.moves[0].newRange == 0..<0)
        #expect(plan.moves[1].uuid == textUUID)
        #expect(plan.moves[1].newRange == 0..<3, "the empty document must not push the next one along")
        #expect(plan.slotCount == 3)
    }

    @Test("An already-compact index plans the identity.")
    func testCompactionPlanOfACompactIndexIsTheIdentity() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        var cursor = 0
        for index in 0..<12 {
            let length = (index % 4) + 1
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index),
                                                       startSlot: cursor,
                                                       endSlot: cursor + length)
            cursor += length
        }

        let plan = CompactionPlan(documentRanges: ranges)

        for move in plan.moves {
            #expect(move.newRange == move.sourceRange, "nothing to reclaim, so nothing should move")
        }
        #expect(plan.slotCount == cursor)
    }

    @Test("The same document set always plans identically.")
    func testCompactionPlanIsDeterministic() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        for index in 0..<16 {
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index),
                                                       startSlot: index * 3,
                                                       endSlot: index * 3 + 2)
        }

        let first = CompactionPlan(documentRanges: ranges)
        let second = CompactionPlan(documentRanges: ranges)

        try #require(first.moves.count == second.moves.count)
        #expect(first.slotCount == second.slotCount)
        for (a, b) in zip(first.moves, second.moves) {
            #expect(a.uuid == b.uuid)
            #expect(a.sourceRange == b.sourceRange)
            #expect(a.newRange == b.newRange)
        }
    }
    
    @Test("Every document keeps its identity through the move.")
    func testCompactionPlanPreservesDocumentIdentity() async throws {
        var ranges: [UUID: DocumentLog.DocumentRange] = [:]
        for index in 0..<10 {
            ranges[UUID()] = DocumentLog.DocumentRange(id: UInt64(index * 100),
                                                       startSlot: index * 4,
                                                       endSlot: index * 4 + 3)
        }

        let plan = CompactionPlan(documentRanges: ranges)

        try #require(plan.moves.count == ranges.count)
        for move in plan.moves {
            let original = try #require(ranges[move.uuid])
            #expect(move.documentID == original.id, "the SQLite rowid must survive renumbering")
            #expect(move.sourceRange == original.range)
        }
    }
}
