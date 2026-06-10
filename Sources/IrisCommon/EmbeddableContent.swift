//
//  IrisDocument.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

public enum EmbeddableContent: Codable, Sendable {
    case text(content: String)
    case image(content: Data, caption: String?)
}
