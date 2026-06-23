//
//  ReciprocalRankedFusion.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

public struct ReciprocalRankedFusion {
    static let rrfK = 60
    
    public static func rank(inputs: [[Int]]) -> [Int] {
        var scores: [Int: Double] = [:]
        
        for idArray in inputs {
            for (rank, doc) in idArray.enumerated() {
                scores[doc, default: 0] += 1.0 / Double(rrfK + rank)
            }
        }
        
        // Sort by value, then by ID to produce a deterministic sort.
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
