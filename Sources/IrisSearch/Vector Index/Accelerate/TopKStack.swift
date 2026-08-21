//
//  TopKStack.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/19/26.
//

import Foundation

final class TopKStack {
    /// The K value, the top however many items to keep.
    private let capacity: Int
    /// Stores entries into the heap in ascending score order.
    private var stack: [(slot: Int, distance: Float)]

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.stack = []
        self.stack.reserveCapacity(capacity)
    }

    func insert(slot: Int, distance: Float) {
        guard capacity > 0 else { return }

        // If we are already at capacity, check to see if this score will even make it into the stack.
        if stack.count == capacity {
            guard stack[0].distance < distance else { return }
            stack.removeFirst() // O(n)
        }

        // Binary search to find the insertion point in the stack O(log n). Only optimizes the first `capacity` calls to this function since `stack.removeFirst()` is O(n).
        // Adapted from: https://www.geeksforgeeks.org/dsa/implement-lower-bound/
        var low = 0
        var high = stack.count - 1
        var result = stack.count

        while low <= high {
            let mid = low + ((high - low) / 2)
            if stack[mid].distance >= distance {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        stack.insert((slot, distance), at: result)
    }

    func descending() -> [(slot: Int, distance: Float)] {
        return stack.reversed()
    }
}
