//
//  String+Surrounded.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

extension String {
    func surrounded(by string: String) -> String {
        return "\(string)\(self)\(string)"
    }
}
