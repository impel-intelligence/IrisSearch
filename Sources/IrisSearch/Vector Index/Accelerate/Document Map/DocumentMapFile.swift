//
//  DocumentMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class DocumentMapFile {
    let file: BinaryFile
    let header: DocumentMap
    let url: URL

    public init(url: URL, maximumSlotCount: Int) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        header = try DocumentMap(bytes: data.byteArray, maximumSlotCount: maximumSlotCount)
        file = try BinaryFile(url: url)
    }
    
    public static func new(at url: URL, maximumSlotCount: Int, generation: UInt64 = 0) throws -> DocumentMapFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = DocumentMap(generation: generation).encoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try DocumentMapFile(url: url, maximumSlotCount: maximumSlotCount)
    }
}
