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

final class PDFDigester: FileDigester {
    struct RenderedPage: Sendable {
        let index: Int
        let image: CGImage
    }
    
    static let fileTypes: [UTType] = [.pdf, UTType("com.adobe.pdf")!]
    
    let processImages: Bool
        
    init(processImages: Bool = true) {
        self.processImages = processImages
    }
    
    required init() {
        processImages = false
    }
    
    /// Render PDF pages to CGImages
    /// This runs fairly quickly, with a 200 page document taking around ​0.13 seconds. It is not instead, but fairly close.
    ///
    /// - Parameter document: the PDFDocument to render from
    /// - Returns: A set of CGImages for each page in the PDF, rendered at the same size they are in the PDF.
    func renderPages(from document: PDFDocument) async throws -> [RenderedPage] {
        // A wrapper struct that puts a PDF page into a "sendable" struct so it can pass the task boundary. Unsafe, but we don't need to worry since we never modify the data, just read.
        struct SendablePage: @unchecked Sendable {
            let page: PDFPage
            let index: Int
        }
        
        let pages: [SendablePage] = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: 0) else { return nil }
            return SendablePage(page: page, index: index)
        }
                
        return try await withThrowingTaskGroup(of: RenderedPage?.self) { group in
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
                    guard let image = context.makeImage() else { return nil }
                    return RenderedPage(index: wrapper.index, image: image)
                }
            }
            
            var renderedPages: [RenderedPage] = []
            
            // Gather results as they finish
            for try await result in group {
                guard let page = result else { continue }
                renderedPages.append(page)
            }
            
            return renderedPages
        }
    }
    
    func digest(file: URL) async throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try PDFDigester.validateLocalURL(file)

        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { throw DigestionError.failedToReadContents }
        
        guard let pdfDocument = PDFDocument(data: data) else { throw PDFDigestionError.couldNotCreateDocument }
        
        var contentPieces: [EmbeddableContent] = []
        
        for index in 0..<pdfDocument.pageCount {
            let page = pdfDocument.page(at: index)
            guard let pageContent = page?.string else { continue }
            contentPieces.append(.text(content: pageContent))
        }
        
        // If per-page string extraction failed, extract all of the text in the PDF.
        if contentPieces.isEmpty, let content = pdfDocument.string {
            contentPieces.append(.text(content: content))
        }
        
        // If we aren't processing images, back out early and return the existing content
        guard processImages else { return contentPieces }
        
        let renderedPages = try await renderPages(from: pdfDocument)
        
        for page in renderedPages {
            guard let jpgData = page.image.jpgData else { continue }
            contentPieces.append(.image(content: jpgData, caption: "Page \(page.index) of PDF"))
        }

        return contentPieces
    }
}
