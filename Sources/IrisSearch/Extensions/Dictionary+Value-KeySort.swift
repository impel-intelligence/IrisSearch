//
//  Dictionary+Value-KeySort.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/29/26.
//

extension Dictionary where Value: Comparable, Key: Comparable {
    func sortedByValueThenKey() -> [Element] {
        sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key < rhs.key
        }
    }
}
