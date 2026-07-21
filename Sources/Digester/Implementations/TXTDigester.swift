//
//  TxtDigester.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation

/// A catch-all text digester that can handle basic text documents.
///
/// There is no "structure" to the documents digested, They are chunked based purely on the
/// `contextSize` provided at digestion time.
final class TXTDigester: FileDigester {
    /// File types supported by the text digester.
    ///
    /// # Custom Types
    /// | Description | UTI | Extensions | Conforms to | MIME types | Reference |
    /// | --- | --- | --- | --- | --- | --- |
    /// | Markdown document | net.daringfireball.markdown | .md, .markdown | public.plain-text | text/markdown | https://daringfireball.net/projects/markdown/ |
    static let fileTypes: [UTType] = [.text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText, UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]

    required init() { }
    
    /// Digest a plain-text file into `EmbeddableContent` chunks of size `contextSize`. There is no
    /// document structure processing.
    ///
    /// Document positioning are provided by the character range of text within the greater document.
    /// - Parameters:
    ///   - file: The plain-text file to turn into `EmbeddableContent`
    ///   - contextSize: The size of embeddable content chunks to return.
    /// - Returns: An array of `EmbeddableContent` that was produced by sentence chunking of
    ///            the input `file.`
    func digest(file: URL, contextSize: Int) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try TXTDigester.validateLocalURL(file)

        var usedEncoding: String.Encoding = .utf8
        let stringContent = try String(contentsOf: file, usedEncoding: &usedEncoding)

        return SentenceChunker.chunkContent(for: stringContent, contextSize: contextSize) { range in
            return .text(characterRange: range)
        }
    }
}
