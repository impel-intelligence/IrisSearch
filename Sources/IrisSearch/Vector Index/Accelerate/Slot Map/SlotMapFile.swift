//
//  SlotMapFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation

final class SlotMapFile {
    let file: BinaryFile
    let map: SlotMap
    let url: URL

    public init(url: URL) throws {
        self.url = url
        let data = try Data.init(contentsOf: url)
        map = try SlotMap(bytes: data.byteArray, fileSize: data.count)
        file = try BinaryFile(url: url)
    }
    
    public static func new(at url: URL, generation: UInt64 = 0) throws -> SlotMapFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = SlotMap(entries: [], generation: generation).encoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try SlotMapFile(url: url)
    }
}
