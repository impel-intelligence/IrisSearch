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
    /// - Note: Offsets are relative to `startIndex`, not to zero. Slices do not rebase.
    func load<T: FixedWidthInteger>(at offset: Int) -> T {
        var value = T.zero
        Swift.withUnsafeMutableBytes(of: &value) { destination in
            for i in 0..<MemoryLayout<T>.size { destination[i] = self[offset + i] }
        }
        return T(littleEndian: value)    }

    func loadUUID(at offset: Int) -> UUID {
        var tuple = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        Swift.withUnsafeMutableBytes(of: &tuple) { destination in
            for i in 0..<16 { destination[i] = self[offset + i] }
        }
        return UUID(uuid: tuple)
    }
}
