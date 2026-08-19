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

}
