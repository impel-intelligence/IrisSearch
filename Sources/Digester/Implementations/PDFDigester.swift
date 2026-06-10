//
//  File.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation
import PDFKit

enum PDFDigestionError: Error {
    case couldNotCreateDocument
}

class PDFDigester: FileDigester {
    static let fileTypes: [UTType] = [.text, .plainText]
    
    func digest(file: URL) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try PDFDigester.validateLocalURL(file)

        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { throw DigestionError.failedToReadContents }
        
        guard let pdfDocument = PDFDocument(data: data) else { throw PDFDigestionError.couldNotCreateDocument }
        
        var contentPieces: [EmbeddableContent] = []
        
        // Extract all of the text in the PDF for text based searching.
        if let content = pdfDocument.string {
            contentPieces.append(.text(content: content))
        }
        
        return []
//
//        if let pdf = PDFDocument(data: data) {
//            guard var string = pdf.string else {
//                throw CDError.pdfStringExtractionFailed
//            }
//            
//            let documentTitleRange = string.lineRange(for: string.startIndex...string.startIndex) // Get the first line of the document
//            let documentTitle = string[documentTitleRange].trimmingCharacters(in: .whitespacesAndNewlines)
//            
//            string.replace("\n", with: "")
//            string.replace("<EOS>", with: "")
//            string.replace("<pad>", with: "")
//            string = string.trimmingCharacters(in: .whitespaces)
//            
//            var documentContent: String = "\(documentTitle)\n"
//            for x in 0..<pdf.pageCount {
//                let page = pdf.page(at: x)!
//                var pageString = page.attributedString?.string ?? ""
//                pageString.replace("\n", with: "")
//                pageString.replace("<EOS>", with: "")
//                pageString.replace("<pad>", with: "")
//                pageString = pageString.trimmingCharacters(in: .whitespaces)
//                
//                if x != 0 {
//                    pageString = pageString.replacingOccurrences(of: documentTitle, with: "")
//                }
//                
//                documentContent.append(pageString)
//            }
//            
//            return (documentContent, .pdf)
//        }


    }
}
