//
//  Array+SpecificType.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/21/26.
//

import UniformTypeIdentifiers

extension Array where Element == UTType {
    /// Find the type in this array that conforms to every other type in the array. Used to find the bottom of a conformance chain.
    func mostSpecificType(conformingTo type: UTType) -> UTType? {
        self.first { a in
            type.conforms(to: a) && self.allSatisfy { b in
                !type.conforms(to: b) || a == b || a.conforms(to: b)
            }
        }
    }
}
