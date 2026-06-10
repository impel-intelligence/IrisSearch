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

extension CGImage {
    var jpgData: Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: self)
        return bitmapRep.representation(using: .jpeg, properties: [:])
    }
}

enum PDFDigestionError: Error {
    case couldNotCreateDocument
}

class PDFDigester: FileDigester {
    static let fileTypes: [UTType] = [.pdf, UTType("com.adobe.pdf")!]
    
    /// Render PDF pages to CGImages
    /// This runs fairly quickly, with a 200 page document taking around ​0.13 seconds. It is not instead, but fairly close.
    ///
    /// - Parameter document: the PDFDocument to render from
    /// - Returns: A set of CGImages for each page in the PDF, rendered at the same size they are in the PDF.
    func renderPages(from document: PDFDocument) async throws -> [CGImage] {
        // A wrapper struct that puts a PDF page into a "sendable" struct so it can pass the task boundary. Unsafe, but we don't need to worry since we never modify the data, just read.
        struct SendablePage: @unchecked Sendable {
            let page: PDFPage
        }
        
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }.map { SendablePage(page: $0) }
        
        return try await withThrowingTaskGroup(of: CGImage?.self) { group in
            for wrapper in pages {
                group.addTask {
                    let page = wrapper.page
                    let rect = page.bounds(for: .mediaBox)
                    
                    guard let context = CGContext(
                        data: nil,
                        width: Int(rect.width),
                        height: Int(rect.height),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else { return nil }
                    
                    page.draw(with: .mediaBox, to: context)
                    return context.makeImage()
                }
            }
            
            var images: [CGImage] = []
            
            // Gather results as they finish
            for try await result in group {
                guard let image = result else { continue }
                images.append(image)
            }
            
            return images
        }
    }
    
    func digest(file: URL) async throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try PDFDigester.validateLocalURL(file)

        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { throw DigestionError.failedToReadContents }
        
        guard let pdfDocument = PDFDocument(data: data) else { throw PDFDigestionError.couldNotCreateDocument }
        
        var contentPieces: [EmbeddableContent] = []
        
        // Extract all of the text in the PDF for text based searching.
        if let content = pdfDocument.string {
            contentPieces.append(.text(content: content))
        }
        
        let pageImages = try await renderPages(from: pdfDocument)
        
        for (index, page) in pageImages.enumerated() {
            guard let jpgData = page.jpgData else { continue }
            contentPieces.append(.image(content: jpgData, caption: "Page \(index) of PDF"))
        }

        return contentPieces
    }
}
