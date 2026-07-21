//
//  ImageDecoder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/21/26.
//

import Foundation
import CoreGraphics
import ImageIO

/// Decode images from local and remote urls.
struct ImageDecoder {
    /// An error produced during image decoding.
    enum ImageDecodingError: Error {
        /// The relative URL for an image could not be constructed.
        case couldNotCreateURL
        /// The response object from a remote image was not valid.
        case invalidResponseObject
        /// The response `code` from a remote image was not in the 200...299 range.
        case invalidResponseCode(code: Int)
        /// The remote image did not provide a mime type, so it can not be safety checked,
        case noMimeType
        /// The mime type provided by the remote image is not an image based mime type (`image/`).
        case invalidMimeType(type: String)
        /// The data from the provided URL was not of an image format recognized by Core Graphics.
        case invalidImageData
    }
    
    /// Determine if data is a valid image according to Core Graphics.
    /// - Parameter data: The data to be checked for image conformance.
    /// - Returns: True if the data was recognized as an image by Core Graphics, false otherwise.
    private func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }

        // Check to make sure the format is valid
        guard CGImageSourceGetType(source) != nil else { return false }

        return true
    }
    
    /// Load and validate an image from a local or remote URL.
    /// - Parameter url: The URL to load the image from.
    /// - Returns: Validated image data loaded from the given `url`
    func loadImage(url: URL) async throws -> Data {
        if url.isFileURL {
            let imageData = try Data(contentsOf: url, options: .mappedIfSafe)
            
            guard isValidImageData(imageData) else {
                throw ImageDecodingError.invalidImageData
            }
            
            return imageData
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageDecodingError.invalidResponseObject
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ImageDecodingError.invalidResponseCode(code: httpResponse.statusCode)
        }

        guard let mimeType = httpResponse.mimeType else {
            throw ImageDecodingError.noMimeType
        }
        
        guard mimeType.starts(with: "image/") else {
            throw ImageDecodingError.invalidMimeType(type: mimeType)
        }
        
        guard isValidImageData(data) else {
            throw ImageDecodingError.invalidImageData
        }
        
        return data
    }
    
    /// Load an image from the `src` string, relative to a provided url.
    /// - Parameters:
    ///   - src: The relative or absolute url for the image.
    ///   - file: The file to base relative URL resolution of off.
    /// - Returns: Validated image data loaded from the given `src` + `file`
    func loadImage(src: String, relativeTo file: URL) async throws -> Data {
        guard let url = URL(string: src, relativeTo: file) else {
            throw ImageDecodingError.couldNotCreateURL
        }
        
        return try await loadImage(url: url)
    }
}
