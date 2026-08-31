//
//  FaultInjector.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/25/26.
//

typealias FaultInjector = @Sendable (FaultPoint) throws -> Void

enum FaultPoint: CaseIterable {
    case afterReserve
    case afterVectorWrite
    case afterMapWrite
    case afterRecordAppend
    case beforeSlotCountBump
    case afterSlotCountBump
    case beforeCurrentRename
    case afterCurrentRename
    case afterMapTombstone
    case afterDeadRecordAppend
    
    case compactionBeforeDeleteGeneration
    
    case compactorAfterReserve
    case compactorAfterMapWrite
    case compactorAfterRecordAppend
    case compactorAfterVectorWrite
}
