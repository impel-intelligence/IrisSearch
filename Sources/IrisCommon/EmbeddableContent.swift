//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

public enum DocumentAnchor: Codable, Sendable, CustomStringConvertible {
    case text(characterRange: Range<Int>)
    case pdf(page: Int, characterRange: Range<Int>?)
    
    public var description: String {
        switch self {
        case .text(let characterRange):
            return "Characters: \(characterRange.lowerBound) up to \(characterRange.upperBound)"
        case .pdf(let page, let characterRange):
//            if let characterRange {
//                return "Page \(page), Characters: \(characterRange.lowerBound) up to \(characterRange.upperBound)"
//            } else {
                return "Page \(page)"
//            }
        }
    }
}

public struct DocumentChunk: Codable, Sendable {
    public var index: Int
    public var totalChunks: Int
    
    public init(index: Int, totalChunks: Int) {
        self.index = index
        self.totalChunks = totalChunks
    }
}

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

public enum EmbeddableContent: Codable, Sendable {
    /// A simple integer representation of the content type. Used for loading embeddable content from the SQL database.
    public enum ContentType: Int {
        case text = 0
        case image = 1
    }
    
    case text(content: String, location: DocumentLocation)
    case image(content: Data, caption: String?, location: DocumentLocation)
    
    /// Get the content type for this type of embedding.
    /// Used to save an easily recognizable representation of the content type into SQL.
    public var contentType: ContentType {
        switch self {
        case .text:
            return .text
        case .image:
            return .image
        }
    }
}

extension EmbeddableContent {    
    public func withNewDocumentLength(length: Int) -> EmbeddableContent {
        switch self {
        case .text(let content, var location):
            location.documentLength = length
            return .text(content: content, location: location)
        case .image(let content, let caption, var location):
            location.documentLength = length
            return .image(content: content, caption: caption, location: location)
        }
    }
}

public extension EmbeddableContent {
    var textContent: String? {
        switch self {
        case .text(let content, _):
            return content
        case .image(_, let caption, _):
            return caption
        }
    }
    
    var location: DocumentLocation {
        switch self {
        case .text(_, let location):
            return location
        case .image(_, _, let location):
            return location
        }
    }
}
