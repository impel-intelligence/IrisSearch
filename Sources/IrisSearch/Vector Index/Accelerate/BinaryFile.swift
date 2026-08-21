//
//  BinaryFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

import Foundation

class BinaryFile {
    internal var handle: FileHandle
    
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
    
    func scale(to offset: UInt64) throws {
        try handle.truncate(atOffset: offset)
    }
    
    func synchronize() throws {
        try handle.synchronize()
    }
    
    /// A synchronize that performs a full flush to disk. On macOS this performs an `F_FULLFSYNC`, on linux and other platforms it just performs `synchronize`.
    ///
    /// macOS requires  `F_FULLFSYNC` for the contents of a file to actually be flushed to disk. Regular handle.synchronize is good enough for situations that are not power-loss. However if the computer loses power the only way to ensure the data is actually on-disk is to run this.
    ///
    /// Source: https://danluu.com/file-consistency/#:~:text=OS%20X%20requires%20fcntl(F_FULLFSYNC)%20to%20flush%20to%20disk
    func fullSynchronize() throws {
        #if canImport(Darwin)
        try FileDurability.fullSync(handle: handle)
        #else
        self.synchronize()
        #endif
    }
}
