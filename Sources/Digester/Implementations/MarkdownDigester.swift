//
//  MarkdownDigester.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/4/26.
//  Edited by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation

/// A markdown digester, that chunks based on markdown sections.
final class MarkdownDigester: FileDigester {
    /// File types supported by the markdown digester.
    ///
    /// # Custom Types
    /// | Description | UTI | Extensions | Conforms to | MIME types | Reference |
    /// | --- | --- | --- | --- | --- | --- |
    /// | Markdown document | net.daringfireball.markdown | .md, .markdown | public.plain-text | text/markdown | https://daringfireball.net/projects/markdown/ |
    ///
    /// The system-declared type is preferred over the imported one. `UTType(importedAs:conformingTo:)`
    /// only resolves to `net.daringfireball.markdown` when the running process declares or imports that
    /// identifier in its `Info.plist`; in a process that does not — a command line tool, for instance —
    /// it silently returns a generated `com.unknown.md` type instead. That type does not compare equal
    /// to the `UTType(filenameExtension: "md")` a caller derives from a real file, so the factory would
    /// route Markdown to ``TXTDigester`` and ``FileDigester/validateLocalURL(_:)`` would then reject it
    /// outright. Resolving the declared type first makes Markdown digestion work the same way whether or
    /// not the host process declares the identifier, and falls back to the import when the system does
    /// not know the type at all.
    static let fileTypes: [UTType] = [
        UTType("net.daringfireball.markdown") ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    ]

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
        try MarkdownDigester.validateLocalURL(file)

        var usedEncoding: String.Encoding = .utf8
        let stringContent = try String(contentsOf: file, usedEncoding: &usedEncoding)

        return MarkdownChunker.chunkContent(for: stringContent, contextSize: contextSize)
    }
}
