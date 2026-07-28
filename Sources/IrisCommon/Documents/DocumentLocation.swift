//
//  DocumentLocation.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import Foundation

public struct DocumentLocation: Codable, Sendable {
    /// The 0 indexed sequence of locations
    public var sequenceIndex: Int
    
    /// The total number of locations in a document
    public var documentLength: Int

    /// Where in the document this location is
    public var anchor: DocumentAnchor
        
    public init(sequenceIndex: Int, documentLength: Int, anchor: DocumentAnchor) {
        self.sequenceIndex = sequenceIndex
        self.documentLength = documentLength
        self.anchor = anchor
    }
}

extension DocumentLocation {
    public func moveSequence(to newIndex: Int) -> DocumentLocation {
        return DocumentLocation(sequenceIndex: newIndex, documentLength: self.documentLength, anchor: self.anchor)
    }
}
