//
//  TextLocation.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/4/26.
//

public struct TextLocation: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String {
        return "line (\(line)) column(\(column))"
    }

    public static func < (lhs: TextLocation, rhs: TextLocation) -> Bool {
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }
}
