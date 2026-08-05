//
//  DocumentAnchor.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import Foundation

public enum DocumentAnchor: Codable, Sendable, CustomStringConvertible {
    case text(characterRange: Range<Int>)
    case location(textRange: Range<TextLocation>)
    case pdf(page: Int, characterRange: Range<Int>?)
    case selector(selectors: [String])
    
    public var description: String {
        switch self {
        case .text(let characterRange):
            return "Characters: \(characterRange.lowerBound) up to \(characterRange.upperBound)"
        case .pdf(let page, _):
//            if let characterRange {
//                return "Page \(page), Characters: \(characterRange.lowerBound) up to \(characterRange.upperBound)"
//            } else {
                return "Page \(page)"
//            }
        case .selector(let selectors):
            return "Selectors: \(selectors.joined(separator: ", "))"
        case .location(let characterRange):
            return "Location: \(characterRange.lowerBound.description) to \(characterRange.upperBound.description)"
        }
    }
}
