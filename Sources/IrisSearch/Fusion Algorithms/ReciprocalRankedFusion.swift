//
//  ReciprocalRankedFusion.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

struct ReciprocalRankedFusion: FusionAlgorithm {
    static let rrfK = 60
    
    static func rank(inputs: [[Int]]) -> [Int] {
        var scores: [Int: Int] = [:]
        
        for idArray in inputs {
            for (rank, doc) in idArray.enumerated() {
                scores[doc, default: 0] += 1 / (rrfK + rank)
            }
        }
        
        return scores.sorted { $0.1 < $1.1 }.map({$0.key})
    }
}
