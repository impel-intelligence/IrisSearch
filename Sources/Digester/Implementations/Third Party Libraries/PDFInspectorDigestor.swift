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
import PDFInspector

final class PDFInspectorDigester: FileDigester, Sendable {
    static let fileTypes: [UTType] = [.pdf]
    
    required init() { }

    func digest(file: URL, contextSize: Int) async throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try PDFDigester.validateLocalURL(file)

        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { throw DigestionError.fileNotReadable }

        var contentPieces: [EmbeddableContent] = []

        let pdfResult = try processPdfBytes(data: data)
//        print(pdfResult.markdown)
        
        
        
        return contentPieces
    }
}
#endif
