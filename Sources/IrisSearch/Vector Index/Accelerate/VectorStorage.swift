//
//  VectorStorage.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/12/26.
//

import Foundation

public class VectorStorage {
    let source: URL
    let data: Data
    let header: StorageHeader
    
    // Where the data block begins
    private var dataOffset: Int
    
    // Vectors block starts after all IDs
    private var vectorsOffset: Int {
        dataOffset + Int(header.vectorCount) * MemoryLayout<UInt64>.stride
    }

    init(from url: URL) throws {
        source = url
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        header = try VectorStorageHeader.load(data: data)
        dataOffset = header.headerByteOffset
    }
    
    static func new(at url: URL, dimensions: Int) throws -> VectorStorage {
        let header = VectorStorageHeader.V1(vectorCount: 0, dimensions: UInt64(dimensions))
        try header.data().write(to: url)
        return try VectorStorage(from: url)
    }
    
    func insertVector(id: UInt64, vector: [Float]) throws {
        
    }
        
    func withIDs<R>(_ body: (UnsafeBufferPointer<UInt64>) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            
            let idPointer = baseAddress.advanced(by: dataOffset).assumingMemoryBound(to: UInt64.self)
            return try body(UnsafeBufferPointer(start: idPointer, count: Int(header.vectorCount)))
        }
    }
    
    func withVectors<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }

            let idPointer = baseAddress.advanced(by: vectorsOffset).assumingMemoryBound(to: Float.self)
            let count = Int(header.vectorCount) * Int(header.dimensions)
            return try body(UnsafeBufferPointer(start: idPointer, count: count))
        }
    }
}

protocol StorageHeader {
    /// The number of bits that the header takes up.
    static var byteSize: Int { get }
    
    /// Header version to try and load, this is in the same position in all header versions. Max 128 versions of the header
    var headerVersion: UInt8 { get }
    /// How many vectors are stored in this file
    var vectorCount: UInt64 { get }
    /// The dimension of each vector
    var dimensions: UInt64 { get }
    
    func data() -> Data
    
    static func load(data: Data) -> StorageHeader
}

extension StorageHeader {
    /// Allows clients to access the data offset for this header type without knowing the concrete type.
    var headerByteOffset: Int { Self.byteSize }
}

enum HeaderLoadError: Error {
    case invalidVersion
}

//offset 0      magic "IRIS" (4B)
//offset 4      version (u8) + pad
//offset 8      dimensions      (u64)
//offset 16     slotCount       (u64)   // high-water mark of allocated slots
//offset 24     capacity        (u64)   // slots the file can currently hold
//offset 32     deadCount       (u64)   // compaction trigger
//offset 40…    reserved, zeroed
//offset 4096   vectors: capacity × d × 4, row-major

enum VectorStorageHeader {
    static let MAGIC = [0x49, 0x52, 0x49, 0x53]
    
    static func load(data: Data) throws -> StorageHeader {
        // The first byte is the version identifier
        let version: UInt8 = data[0]
        
        // Load the header version that matches the first bit's version identifier. Then give it only the amount of data it actually needs.
        if version == 1 {
            return V1.load(data: data[0..<V1.byteSize])
        } else {
            throw HeaderLoadError.invalidVersion
        }
    }

    struct V1: StorageHeader {
        /// A tally of the header size, needs to be manually kept up to date with the struct members.
        static let byteSize: Int = MemoryLayout<UInt8>.size + MemoryLayout<UInt64>.size +  MemoryLayout<UInt64>.size

        /// Header version to try and load, this is in the same position in all header versions. Max 128 versions of the header
        let headerVersion: UInt8 = 1
        /// Vectors are always loaded next to their ID so we only need a single count to tell the shape of the data
        let vectorCount: UInt64
        
        let dimensions: UInt64
        
        init(vectorCount: UInt64, dimensions: UInt64) {
            self.vectorCount = vectorCount
            self.dimensions = dimensions
        }
        
        /// Serializes this header to its on-disk byte representation.
        func data() -> Data {
            var result = Data(capacity: V1.byteSize)
            withUnsafeBytes(of: VectorStorageHeader.MAGIC) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: headerVersion) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: vectorCount)   { result.append(contentsOf: $0) }
            withUnsafeBytes(of: dimensions)    { result.append(contentsOf: $0) }
            return result
        }
        
        static func load(data: Data) -> any StorageHeader {
            let countEnd = (1 + MemoryLayout<UInt64>.size)
            // loadUnaligned is required because sub-slices of Data are not guaranteed to be UInt64-aligned
            let vectorCount = data[1..<countEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }

            let dimensionsEnd = (countEnd + MemoryLayout<UInt64>.size)
            let dimensions = data[countEnd..<dimensionsEnd].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }

            return VectorStorageHeader.V1(vectorCount: vectorCount, dimensions: dimensions)
        }
    }
}

