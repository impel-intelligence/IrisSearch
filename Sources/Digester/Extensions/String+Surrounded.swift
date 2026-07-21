//
//  String+Surrounded.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

extension String {
    /// Surrounds a string in the given `string`.
    /// - Parameter string: The string to surround this string with.
    /// - Returns: `self`, with `string` at the beginning and end.
    func surrounded(by string: String) -> String {
        return "\(string)\(self)\(string)"
    }
}
