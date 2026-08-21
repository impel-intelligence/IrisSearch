//
//  BitWriting.swift
//  IrisSearch
//
//  Created by Claude Opus 5 (Anthropic) on 8/13/26.
//

import Foundation

extension Array where Element == UInt8 {
    mutating func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        // Swift-qualified: unqualified, this resolves to Array's instance method, not the global function.
        Swift.withUnsafeBytes(of: value.littleEndian) { source in
            for i in 0..<source.count { self[offset + i] = source[i] }
        }
    }

    mutating func store(_ value: UUID, at offset: Int) {
        // Swift-qualified: unqualified, this resolves to Array's instance method, not the global function.
        Swift.withUnsafeBytes(of: value.uuid) { source in     // .uuid is a 16-byte tuple, not the struct
            for i in 0..<16 { self[offset + i] = source[i] }
        }
    }
}

extension Collection where Element == UInt8, Index == Int {
    /// - Note: `offset` is relative to `startIndex`, not to zero, so a slice reads from its own
    ///   origin. Array subscripts elsewhere are still absolute — the two do not agree, and
    ///   `store` takes an absolute index.
    func load<T: FixedWidthInteger>(at offset: Int) -> T {
        let base = startIndex + offset
        var value = T.zero
        Swift.withUnsafeMutableBytes(of: &value) { destination in
            for i in 0..<MemoryLayout<T>.size { destination[i] = self[base + i] }
        }
        return T(littleEndian: value)
    }

    /// - Note: `offset` is relative to `startIndex`, matching `load(at:)`.
    func loadUUID(at offset: Int) -> UUID {
        let base = startIndex + offset
        var tuple = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        Swift.withUnsafeMutableBytes(of: &tuple) { destination in
            for i in 0..<16 { destination[i] = self[base + i] }
        }
        return UUID(uuid: tuple)
    }
}
