//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

public enum DocumentAnchor: Codable, Sendable {
    case text(characterRange: Range<Int>)
    case pdf(page: Int, characterRange: Range<Int>?)
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

    /// Where in the document this location is
    public var anchor: DocumentAnchor
    
    /// If this location was created during chunking, track that here.
    public var chunk: DocumentChunk?
    
    public init(sequenceIndex: Int, anchor: DocumentAnchor, chunk: DocumentChunk? = nil) {
        self.sequenceIndex = sequenceIndex
        self.anchor = anchor
        self.chunk = chunk
    }
}

public extension DocumentLocation {
    func chunk(index: Int, totalChunks: Int, chunkSize: Int?) -> DocumentLocation {
        var newAnchor = self.anchor
        
        return DocumentLocation(
            sequenceIndex: self.sequenceIndex,
            anchor: newAnchor,
            chunk: DocumentChunk(index: index, totalChunks: totalChunks)
        )
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
