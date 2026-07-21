//
//  ImageDecoder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/21/26.
//

import Foundation
import CoreGraphics
import ImageIO

struct ImageDecoder {
    enum ImageDownloadError: Error {
        case couldNotCreateURL
        case invalidResponseObject
        case invalidResponseCode(code: Int)
        case noMimeType
        case invalidMimeType(type: String)
        case invalidImageData
    }
    
    private func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }

        // Check to make sure the format is valid
        guard CGImageSourceGetType(source) != nil else { return false }

        return true
    }
    
    func loadImage(url: URL) async throws -> Data? {
        if url.isFileURL {
            let imageData = try Data(contentsOf: url, options: .mappedIfSafe)
            
            guard isValidImageData(imageData) else {
                throw ImageDownloadError.invalidImageData
            }
            
            return imageData
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageDownloadError.invalidResponseObject
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ImageDownloadError.invalidResponseCode(code: httpResponse.statusCode)
        }

        guard let mimeType = httpResponse.mimeType else {
            throw ImageDownloadError.noMimeType
        }
        
        guard mimeType.starts(with: "image/") else {
            throw ImageDownloadError.invalidMimeType(type: mimeType)
        }
        
        guard isValidImageData(data) else {
            throw ImageDownloadError.invalidImageData
        }
        
        return data
    }
    
    func loadImage(src: String, relativeTo file: URL) async throws -> Data? {
        guard let url = URL(string: src, relativeTo: file) else {
            throw ImageDownloadError.couldNotCreateURL
        }
        
        return try await loadImage(url: url)
    }
}
