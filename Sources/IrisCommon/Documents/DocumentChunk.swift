//
//  DocumentChunk.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import Foundation

public struct DocumentChunk: Codable, Sendable {
    public var index: Int
    public var totalChunks: Int
    
    public init(index: Int, totalChunks: Int) {
        self.index = index
        self.totalChunks = totalChunks
    }
}

