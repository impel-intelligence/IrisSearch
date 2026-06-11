//
//  TextChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

import IrisCommon

protocol TextChunker {
    func chunk(content: String) -> [String]
}
