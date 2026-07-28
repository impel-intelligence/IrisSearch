//
//  SearchResult.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/24/26.
//

public struct SearchResult: Sendable {
    public let document: IrisDocument
    public let importantPieces: [DocumentPiece]
}
