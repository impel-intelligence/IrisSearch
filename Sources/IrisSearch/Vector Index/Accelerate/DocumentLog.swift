//
//  DocumentLog.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

import Foundation

/// An append only log that maps Iris Documents to their vector slots.
final class DocumentLog {
    private let file: BinaryFile
    private(set) var map: DocumentMap
    
    init(file: BinaryFile, map: DocumentMap) {
        self.file = file
        self.map = map
    }
    
    func append(record: DocumentMap.Record) throws {
        try file.append(data: Data(record.encoded()))
        map.apply(record: record)
    }
}
