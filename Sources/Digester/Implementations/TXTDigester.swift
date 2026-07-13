//
//  TxtDigester.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation

final class TXTDigester: FileDigester {
    static let fileTypes: [UTType] = [.text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText, UTType(importedAs: "net.daringfireball.markdown")]
    
    required init() { }
    
    func digest(file: URL) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try TXTDigester.validateLocalURL(file)

        var usedEncoding: String.Encoding = .utf8
        let stringContent = try String(contentsOf: file, usedEncoding: &usedEncoding)
        
        let location = DocumentLocation(sequenceIndex: 0, anchor: .text(characterRange: 0..<stringContent.count))
        
        return [ .text(content: stringContent, location: location) ]
    }
}
