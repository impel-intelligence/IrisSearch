//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

public enum EmbeddableContent: Codable, Sendable {
    /// A simple integer representation of the content type. Used for loading embeddable content from the SQL database.
    public enum ContentType: Int {
        case text = 0
        case image = 1
    }
    
    case text(content: String)
    case image(content: Data, caption: String?)
    
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
        case .text(let content):
            return content
        case .image(_, let caption):
            return caption
        }
    }
}
