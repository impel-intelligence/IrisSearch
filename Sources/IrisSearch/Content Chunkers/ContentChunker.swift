//
//  ContentChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/7/26.
//

protocol ContentChunker {
    func chunk(content: String) -> [String]
}

