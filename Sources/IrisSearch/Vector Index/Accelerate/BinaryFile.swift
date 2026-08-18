//
//  BinaryFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

import Foundation

final class BinaryFile {
    private var handle: FileHandle
    
    init(url: URL) throws {
        self.handle = try FileHandle(forUpdating: url)
    }
    
    func write(data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }
    
    func append(data: Data) throws {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    
    func grow(to offset: UInt64) throws {
        try handle.truncate(atOffset: offset)
    }
    
    func synchronize() throws {
        try handle.synchronize()
    }
}
