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
}

protocol FileDigester {
    static var fileTypes: [UTType] { get }
    
    func digest(file: URL) async throws -> [EmbeddableContent]
}

extension FileDigester {
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL else { throw DigestionError.notAFileURL }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { throw DigestionError.fileNotReadable }
        guard let fileType = UTType(filenameExtension: url.pathExtension) else { throw DigestionError.incorrectExtension }
        guard fileTypes.contains(fileType) else { throw DigestionError.fileTypeNotValid(type: fileType)}
    }
}
