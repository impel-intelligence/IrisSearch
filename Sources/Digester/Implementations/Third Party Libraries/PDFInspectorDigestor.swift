//
//  PDFInspectorDigestor.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/4/26.
//

#if pdf_inspector
import UniformTypeIdentifiers
import IrisCommon
import Foundation
import pdf_inspector_swift

public enum PDFInspectorDigesterError: Error {
    case noMarkdown
}

final class PDFInspectorDigester: FileDigester, Sendable {
    static let fileTypes: [UTType] = [.pdf]
    
    required init() { }

    func digest(file: URL, contextSize: Int) async throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try PDFDigester.validateLocalURL(file)

        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { throw DigestionError.fileNotReadable }

        let pdfResult = try processPdfBytes(data: data)
        
        guard let markdown = pdfResult.markdown else { throw PDFInspectorDigesterError.noMarkdown }

        // Parse and chunk markdown
        return MarkdownChunker.chunkContent(for: markdown, contextSize: contextSize)
    }
}
#endif
