//
//  empty.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import IrisCommon
import UniformTypeIdentifiers

enum DigestionError: Error {
    case fileNotReadable
    case emptyFile
    case notAFileURL
    case incorrectExtension
    case failedToReadContents
    case fileTypeNotValid(type: UTType)
    case noAvailableDigester(type: UTType)
}

public protocol FileDigester: Sendable, Identifiable {
    static var fileTypes: [UTType] { get }
    
    init()
    
    /// A function that produces chunked content from the given file url.
    func digest(file: URL, contextSize: Int) async throws -> [EmbeddableContent]
}

extension FileDigester {
    static func isValidType(_ type: UTType) -> Bool {
        return Self.fileTypes.contains(where: { type.conforms(to: $0) })
    }
    
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL else { throw DigestionError.notAFileURL }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { throw DigestionError.fileNotReadable }
        guard let fileType = UTType(filenameExtension: url.pathExtension) else { throw DigestionError.incorrectExtension }
        guard fileTypes.contains(fileType) else { throw DigestionError.fileTypeNotValid(type: fileType)}
    }
}
