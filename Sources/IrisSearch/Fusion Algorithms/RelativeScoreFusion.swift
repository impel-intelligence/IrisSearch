//
//  RelativeScoreFusion.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/23/26.
//

public struct RelativeScoreFusion {
    enum RankingError: Error {
        case inputsAndWeightCountMustMatch
    }
    
    public static func rank(inputs: [[(id: Int, score: Double)]], weights: [Double]) throws -> [Int] {
        guard inputs.count == weights.count else { return [] }
        var scores: [Int: Double] = [:]
        
        for (input, weight) in zip(inputs, weights) {
            let values = input.map(\.score)
            guard let min = values.min(), let max = values.max() else { continue }
            let range = max - min
            
            for package in input {
                // Min-max normalize this list to [0, 1]; if all equal, treat as 1.
                let normalized = range > 0 ? (package.score - min) / range : 1
                scores[package.id, default: 0] += normalized * weight
            }
        }
        
        // Sort by value, then by ID to produce a deterministic sort.
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
