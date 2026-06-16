//
//  Comparable+Clamped.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
