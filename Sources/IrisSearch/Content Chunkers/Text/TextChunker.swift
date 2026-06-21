//
//  TextChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import IrisCommon

public protocol TextChunker: Sendable {
    init()
    
    func chunk(content: String) -> [String]
}
